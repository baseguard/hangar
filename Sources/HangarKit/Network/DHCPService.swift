import Darwin
import Foundation
import HangarPackets
import HangarSupport
import vmnet

actor DHCPService {
    /// The gateway answers ARP within moments; a VM that asks for a reservation nobody loaded yet gets them read
    /// again, but not for every packet.
    private static let gatewayLookupAttempts = 40
    private static let gatewayLookupInterval: UInt32 = 250_000
    private static let reservationRefresh: TimeInterval = 2
    private static let closeTimeout: DispatchTimeInterval = .seconds(5)

    private let queue = DispatchSerialQueue(label: "io.baseguard.hangar.netd.dhcp")
    private let subnet: IPv4Subnet
    private let address: UInt32
    private let log: @Sendable (String) -> Void
    private var network: vmnet_network_ref?
    private var interface: VMNetInterface?
    let mac: [UInt8]
    private var gateway: [UInt8]?
    private var dhcp: DHCPServer
    private var reservationsLoadedAt = Date.distantPast

    static var leasesURL: URL { HangarPaths.network.appendingPathComponent("leases.json") }

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(subnet: IPv4Subnet, network: vmnet_network_ref, log: @escaping @Sendable (String) -> Void) throws {
        self.subnet = subnet
        self.address = subnet.serverAddress.value
        self.log = log
        var leases: [String: DHCPServer.Lease] = [:]

        do {
            leases = try SharedNetwork.readLeases()
        } catch {
            log("could not read \(Self.leasesURL.path), starting without leases: \(error.localizedDescription)")
        }

        dhcp = DHCPServer(subnet: subnet, serverIP: address, leases: leases)
        let relay = FrameRelay()
        let interface: VMNetInterface

        do {
            interface = try VMNetInterface(network: network, queue: queue) { frame in relay.deliver(frame) }
        } catch {
            releaseVMNet(network)
            throw error
        }

        self.network = network
        self.interface = interface
        mac = interface.mac
        relay.connect { [weak self] frame in
            self?.assumeIsolated { service in service.handleFrame(frame) }
        }
        queue.async { [weak self] in
            self?.assumeIsolated { service in service.announce() }
        }
    }

    nonisolated func close() {
        let stopped = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else {
                stopped.signal()
                return
            }
            assumeIsolated { service in service.release { stopped.signal() } }
        }
        _ = stopped.wait(timeout: .now() + Self.closeTimeout)
    }

    private func release(then stopped: @escaping @Sendable () -> Void) {
        if let interface {
            interface.stop(then: stopped)
        } else {
            stopped()
        }
        interface = nil
        if let network { releaseVMNet(network) }
        network = nil
    }

    nonisolated func gatewayMAC() -> [UInt8]? {
        for _ in 0..<Self.gatewayLookupAttempts {
            let found: [UInt8]? = queue.sync {
                assumeIsolated { service in
                    if service.gateway == nil { service.askForGateway() }
                    return service.gateway
                }
            }
            if let found { return found }
            usleep(Self.gatewayLookupInterval)
        }
        return nil
    }

    private func askForGateway() {
        send(
            Packet.ethernet(
                destination: Packet.broadcastMAC, source: mac, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: ARPPacket.request, senderMAC: mac, senderIP: address, targetMAC: Packet.zeroMAC,
                    targetIP: subnet.gateway.value
                )))
    }

    private func isGatewayReply(_ frame: [UInt8]) -> Bool {
        guard let arp = ARPPacket(frame) else { return false }
        return frame[Packet.destinationMAC].elementsEqual(mac) && arp.operation == ARPPacket.reply
            && arp.senderIP == subnet.gateway.value && arp.targetIP == address
            && arp.senderMAC.elementsEqual(frame[Packet.sourceMAC])
    }

    nonisolated func maintain() {
        queue.async { [weak self] in
            self?.assumeIsolated { service in service.prune() }
        }
    }

    private func announce() {
        reloadReservations()
        log("DHCP server on \(IPv4Address(address)) (\(MACAddress.string(mac)))")
    }

    private func prune() {
        reloadReservations()
        let before = dhcp.leases
        dhcp.pruneLeases()
        if dhcp.leases != before { saveLeases() }
    }

    private func reloadReservations() {
        dhcp.reservations = SharedNetwork.reservations(in: subnet)
        reservationsLoadedAt = Date()
    }

    private func saveLeases() {
        do {
            try JSON.write(dhcp.leases, to: Self.leasesURL)
        } catch {
            log("could not save leases: \(error.localizedDescription)")
        }
    }

    private func send(_ frame: [UInt8]) {
        interface?.send(frame)
    }

    private func handleFrame(_ frame: [UInt8]) {
        guard frame.count >= Packet.ethernetHeaderLength, !frame[Packet.sourceMAC].elementsEqual(mac) else { return }

        switch Packet.readUInt16(frame, at: 12) {
        case Packet.etherTypeARP:
            if gateway == nil, isGatewayReply(frame) {
                gateway = ARPPacket(frame)?.senderMAC
            } else {
                answerARP(frame)
            }
        case Packet.etherTypeIPv4:
            guard let ip = IPv4Packet(frame, offset: Packet.ethernetHeaderLength) else { return }
            if let udp = UDPDatagram(ip), udp.destinationPort == DHCPServer.serverPort {
                handleDHCP(frame, ip)
            }
        default:
            break
        }
    }

    private func answerARP(_ frame: [UInt8]) {
        guard let arp = ARPPacket(frame), arp.operation == ARPPacket.request, arp.targetIP == address,
            arp.senderMAC.elementsEqual(frame[6..<12])
        else { return }
        send(
            Packet.ethernet(
                destination: arp.senderMAC, source: mac, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: ARPPacket.reply, senderMAC: mac, senderIP: address, targetMAC: arp.senderMAC,
                    targetIP: arp.senderIP
                )))
    }

    private func handleDHCP(_ frame: [UInt8], _ ip: IPv4Packet) {
        let start = ip.payloadOffset + 8
        let end = ip.offset + ip.totalLength
        guard start < end else { return }

        let bootp = Array(frame[start..<end])
        guard bootp.count >= DHCPServer.Field.clientMAC.upperBound,
            bootp[DHCPServer.Field.clientMAC].elementsEqual(frame[Packet.sourceMAC])
        else { return }

        if let client = DHCPServer.clientMAC(of: bootp), dhcp.reservations[client] == nil,
            Date().timeIntervalSince(reservationsLoadedAt) > Self.reservationRefresh
        {
            reloadReservations()
        }

        let before = dhcp.leases
        let reply = dhcp.handle(bootp)
        if dhcp.leases != before { saveLeases() }
        guard let reply else { return }

        let packet = Packet.ipv4(
            source: address, destination: reply.destinationIP, protocol: Packet.protocolUDP,
            payload: Packet.udp(
                sourcePort: DHCPServer.serverPort, destinationPort: DHCPServer.clientPort, payload: reply.payload))
        send(
            Packet.ethernet(destination: reply.destinationMAC, source: mac, type: Packet.etherTypeIPv4, payload: packet)
        )
    }
}
