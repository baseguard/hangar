import Foundation
import HangarPackets

package final class TrafficInspector {
    package struct Output {
        package var toGuest: [[UInt8]] = []
        package var toNetwork: [[UInt8]] = []
        package var events: [TrafficEvent] = []
    }

    struct PendingQuery {
        let name: String
        let type: UInt16
        let server: UInt32
        let askedAt: Date
        var gatewayMAC: [UInt8] = []
    }

    struct NameEntry {
        var names: [String] = []
        var trusted: [String] = []
        var expires: Date
    }

    static let maximumFlows = 20_000
    // Each address keeps up to 4 names and 4 trusted names of up to 253 bytes: about 40 MB at most.
    static let maximumNames = 20_000
    static let maximumPendingQueries = 4096
    // A resolver that takes longer than this has failed anyway; its answer is dropped.
    static let pendingQueryLifetime: TimeInterval = 30
    static let maximumBufferedBytes = 16 << 20
    static let maximumEventsPerSecond = 300
    /// How often the flow table is pruned when full, and how often a full table or a spoof is reported.
    static let pruneInterval: TimeInterval = 1
    static let fullTableReportInterval: TimeInterval = 10
    static let spoofReportInterval: TimeInterval = 10
    /// A DNS answer's names are kept between these, whatever TTL it gave; each address keeps the newest few.
    static let shortestNameLife: UInt32 = 300
    static let longestNameLife: UInt32 = 86_400
    static let namesPerAddress = 4
    /// Echo both ways and the errors in `passedICMPErrors`; `remotePort` keeps the type for flows without one.
    static let allowedICMPTypes: Set<UInt16> = [
        UInt16(ICMPType.echoReply), UInt16(ICMPType.echoRequest), UInt16(ICMPType.destinationUnreachable),
        UInt16(ICMPType.timeExceeded), UInt16(ICMPType.parameterProblem),
    ]
    /// The ICMP errors a guest gets even under rules.
    static let passedICMPErrors: [UInt8] = [
        ICMPType.destinationUnreachable, ICMPType.timeExceeded, ICMPType.parameterProblem,
    ]

    let guestMAC: [UInt8]
    let subnet: IPv4Subnet
    var guestIP: UInt32?
    package var hostAddresses: Set<UInt32> = []
    var policy: TrafficPolicy
    var rules: TrafficRules
    var flows: [FlowKey: TrafficFlow] = [:]
    var names: [UInt32: NameEntry] = [:]
    var aliases: [String: (origin: String, expires: Date)] = [:]
    var pendingQueries: [UInt32: PendingQuery] = [:]
    /// Hosts that have a secret, and the proxy their HTTPS goes to (`TrafficInspector+Secrets`).
    var secretHosts: Set<String> = []
    var secretsProxy: SecretsDiversion?
    /// The diverted connections by the guest's port, to find the one a frame from the proxy belongs to.
    var divertedFlows: [UInt16: FlowKey] = [:]
    let hostMACs: [UInt32: [UInt8]]
    var bufferedBytes = 0
    /// Flow ids are "<prefix>-<number>", with a new prefix for every run, so a log never repeats one.
    let flowIDPrefix = String(UUID().uuidString.prefix(4)).lowercased()
    var flowsOpened = 0
    var lastSpoofReport = Date.distantPast
    var lastFullReport = Date.distantPast
    var lastPrune = Date.distantPast
    var eventWindow = Date.distantPast
    var eventsInWindow = 0
    var suppressedEvents = 0

    package init(
        guestMAC: [UInt8], guestIP: UInt32?, subnet: IPv4Subnet, gatewayMAC: [UInt8], serverMAC: [UInt8],
        policy: TrafficPolicy
    ) {
        self.guestMAC = guestMAC
        self.guestIP = guestIP
        self.subnet = subnet
        self.policy = policy
        hostMACs = [subnet.gateway.value: gatewayMAC, subnet.serverAddress.value: serverMAC]
        rules = TrafficRules(policy)
    }

    package func start(now: Date) -> Output {
        guard tracksFlows else { return Output() }
        return Output(events: [
            TrafficEvent(
                time: now, kind: .start, reason: policy.isolated ? "isolated" : nil, mode: policy.mode.rawValue)
        ])
    }

    package func update(_ policy: TrafficPolicy, now: Date) -> Output {
        var output = Output()
        self.policy = policy
        rules = TrafficRules(policy)
        output.events.append(
            TrafficEvent(
                time: now, kind: .policy, reason: policy.isolated ? "isolated" : nil, mode: policy.mode.rawValue))
        guard tracksFlows else {
            closeFlows(now: now, output: &output)
            return output
        }

        for flow in flows.values {
            redecide(flow, now: now, output: &output)
        }
        return output
    }

    /// A flow the new rules block is reported, and reset by the next frame. An open HTTP connection is blocked too:
    /// its earlier requests weren't inspected under these rules.
    private func redecide(_ flow: TrafficFlow, now: Date, output: inout Output) {
        let before = flow.verdict
        decide(flow)
        if flow.verdict == .allowed { flow.isBlockedAfterClosing = false }
        if policy.enforces, flow.verdict == .allowed, flow.application == .http, !flow.isInspecting, !flow.isClosed {
            flow.verdict = .blocked
            flow.reason = "HTTP connection from before the rules changed"
        }

        guard before == .allowed, flow.verdict == .blocked else { return }
        if flow.isClosed {
            flow.isBlockedAfterClosing = true
        } else {
            flow.reason = "\(flow.reason ?? "blocked") (rules changed)"
            report(flow, now: now, output: &output)
        }
    }

    package func expire(now: Date) -> Output {
        var output = Output()
        flushSuppressed(now: now, output: &output)
        removeIdleFlows(now: now, output: &output)
        names = names.filter { $0.value.expires > now }
        aliases = aliases.filter { $0.value.expires > now }
        for (key, query) in pendingQueries where now.timeIntervalSince(query.askedAt) > Self.pendingQueryLifetime {
            emit(dnsEvent(query, answers: nil, reason: "no answer"), now: now, output: &output)
            pendingQueries[key] = nil
        }
        return output
    }

    package func finish(now: Date) -> Output {
        var output = Output()
        closeFlows(now: now, output: &output)
        flushSuppressed(now: now.addingTimeInterval(1), output: &output)
        return output
    }

    private func closeFlows(now: Date, output: inout Output) {
        for flow in flows.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            close(flow, now: now, output: &output)
        }
        flows = [:]
    }

    package func fromGuest(_ frame: [UInt8], now: Date) -> Output {
        var output = Output()
        guard frame.count >= Packet.ethernetHeaderLength else { return output }
        guard frame[Packet.sourceMAC].elementsEqual(guestMAC) else {
            reportSpoof("a frame from another MAC address", now: now, output: &output)
            return output
        }

        switch Packet.readUInt16(frame, at: 12) {
        case Packet.etherTypeARP:
            guestARP(frame, now: now, output: &output)
        case Packet.etherTypeIPv4:
            if let ip = IPv4Packet(frame, offset: Packet.ethernetHeaderLength) {
                guestIPv4(frame, ip, now: now, output: &output)
            }
        default:
            break
        }

        output.toNetwork = redirectToProxy(output.toNetwork)
        return output
    }

    package func fromNetwork(_ received: [UInt8], now: Date) -> Output {
        var output = Output()
        guard let frame = returnFromProxy(received) else { return output }
        guard frame.count >= Packet.ethernetHeaderLength,
            frame[Packet.destinationMAC].elementsEqual(guestMAC) || frame[0] & 1 == 1
        else { return output }
        switch Packet.readUInt16(frame, at: 12) {
        case Packet.etherTypeARP:
            networkARP(frame, now: now, output: &output)
        case Packet.etherTypeIPv4:
            if let ip = IPv4Packet(frame, offset: Packet.ethernetHeaderLength) {
                networkIPv4(frame, ip, now: now, output: &output)
            }
        default:
            break
        }
        return output
    }

    private func networkARP(_ frame: [UInt8], now: Date, output: inout Output) {
        guard let arp = ARPPacket(frame) else {
            if !policy.enforces { output.toGuest.append(frame) }
            return
        }

        let sender = arp.senderIP
        let senderMAC = arp.senderMAC

        if policy.enforces, let guestIP, sender == guestIP, senderMAC != guestMAC {
            reportSpoof(
                "an ARP claim for the VM's own address \(IPv4Address(sender)) from another MAC address", now: now,
                output: &output)
            return
        }

        if isInfrastructure(sender) {
            if policy.enforces, hostMACs[sender] != senderMAC {
                reportSpoof(
                    "an ARP claim for \(IPv4Address(sender)) from another MAC address", now: now, output: &output)
                return
            }
        } else if !canReachVM(sender) {
            return
        }

        output.toGuest.append(frame)
    }

    /// Not every VM may be reached, so what goes to all of them, like broadcasts, is kept from this one.
    private var isCutOffFromVMs: Bool { policy.isolated || (policy.enforces && !policy.allowsVMs) }

    private func isInfrastructure(_ address: UInt32) -> Bool {
        address == subnet.gateway.value || address == subnet.serverAddress.value
    }

    private func requiredMAC(for destination: UInt32) -> [UInt8]? {
        if destination == subnet.serverAddress.value { return hostMACs[destination] }
        if destination == subnet.gateway.value || !isLocal(destination) { return hostMACs[subnet.gateway.value] }
        return nil
    }

    private func guestARP(_ frame: [UInt8], now: Date, output: inout Output) {
        guard let arp = ARPPacket(frame), arp.operation == ARPPacket.request || arp.operation == ARPPacket.reply
        else { return }
        let sender = arp.senderIP
        let target = arp.targetIP
        guard arp.senderMAC == guestMAC, sender == 0 || sender == guestIP else {
            reportSpoof("an ARP claim for another address", now: now, output: &output)
            return
        }

        guard isInfrastructure(target) || target == sender || canReachVM(target) else { return }

        let rebuilt = Packet.arp(
            operation: arp.operation, senderMAC: guestMAC, senderIP: sender, targetMAC: arp.targetMAC,
            targetIP: target)
        output.toNetwork.append(
            Packet.ethernet(
                destination: Array(frame[Packet.destinationMAC]), source: guestMAC, type: Packet.etherTypeARP,
                payload: rebuilt))
    }

    private func guestIPv4(_ frame: [UInt8], _ ip: IPv4Packet, now: Date, output: inout Output) {
        if isDHCPRequest(frame, ip) { return relayDHCPRequest(frame, output: &output) }
        if isGroupReportWithoutAddress(ip) { return }
        guard let guestIP, ip.source == guestIP else {
            return reportSpoof(
                "packets from \(IPv4Address(ip.source))", protocolNumber: ip.protocolNumber, now: now, output: &output)
        }
        if let udp = UDPDatagram(ip), udp.sourcePort == DHCPServer.serverPort,
            udp.destinationPort == DHCPServer.clientPort
        {
            return reportSpoof("a DHCP server reply", protocolNumber: ip.protocolNumber, now: now, output: &output)
        }
        guard tracksFlows else { return output.toNetwork.append(frame) }

        if policy.enforces, let required = requiredMAC(for: ip.destination),
            !frame[Packet.destinationMAC].elementsEqual(required)
        {
            return reportSpoof(
                "packets for \(IPv4Address(ip.destination)) sent to another MAC address",
                protocolNumber: ip.protocolNumber, now: now, output: &output)
        }
        guestPayload(frame, ip, now: now, output: &output)
    }

    /// A guest without an address yet still joins multicast groups, like mDNS's, from 0.0.0.0 (RFC 3376 §4.2.13).
    /// Nothing on this network routes multicast, so the report goes nowhere, and it is no spoof.
    private func isGroupReportWithoutAddress(_ ip: IPv4Packet) -> Bool {
        ip.source == 0 && ip.protocolNumber == Packet.protocolIGMP && IPv4Address(ip.destination).isMulticast
    }

    private func relayDHCPRequest(_ frame: [UInt8], output: inout Output) {
        guard isCutOffFromVMs else { return output.toNetwork.append(frame) }
        guard let server = hostMACs[subnet.serverAddress.value] else { return }
        output.toNetwork.append(server + frame[6...])
    }

    private func guestPayload(_ frame: [UInt8], _ ip: IPv4Packet, now: Date, output: inout Output) {
        if ip.isLaterFragment {
            if !policy.enforces { output.toNetwork.append(frame) }
        } else if let tcp = TCPSegment(ip) {
            guestTCP(frame, tcp, now: now, output: &output)
        } else if let udp = UDPDatagram(ip) {
            if udp.destinationPort == Packet.dnsPort, guestDNS(frame, udp, now: now, output: &output) { return }
            if isQUICToSecretHost(udp, now: now) { return }
            let key = FlowKey(
                protocolNumber: Packet.protocolUDP, guestPort: udp.sourcePort, remote: ip.destination,
                remotePort: udp.destinationPort)
            guestDatagram(frame, key: key, payload: udp.payload.count, now: now, output: &output)
        } else if isTCPOrUDP(ip) {
            if !policy.enforces { output.toNetwork.append(frame) }
        } else if ip.protocolNumber == Packet.protocolICMP {
            guard ip.end >= ip.payloadOffset + 8 else { return }
            guestDatagram(
                frame, key: icmpKey(ip, remote: ip.destination), payload: ip.end - ip.payloadOffset - 8, now: now,
                output: &output)
        } else {
            let key = FlowKey(protocolNumber: ip.protocolNumber, guestPort: 0, remote: ip.destination, remotePort: 0)
            guestDatagram(frame, key: key, payload: ip.end - ip.payloadOffset, now: now, output: &output)
        }
    }

    private func networkIPv4(_ frame: [UInt8], _ ip: IPv4Packet, now: Date, output: inout Output) {
        if let udp = UDPDatagram(ip), udp.sourcePort == DHCPServer.serverPort,
            udp.destinationPort == DHCPServer.clientPort,
            ip.source == subnet.serverAddress.value
        {
            return deliverDHCPReply(frame, ip, udp, now: now, output: &output)
        }
        guard tracksFlows else { return output.toGuest.append(frame) }
        guard ip.destination == guestIP else {
            if isLocal(ip.destination), !isCutOffFromVMs { output.toGuest.append(frame) }
            return
        }
        networkPayload(frame, ip, now: now, output: &output)
    }

    private func deliverDHCPReply(
        _ frame: [UInt8], _ ip: IPv4Packet, _ udp: UDPDatagram, now: Date, output: inout Output
    ) {
        let reply = Array(ip.bytes[udp.payload])
        guard reply.count >= DHCPServer.Field.clientMAC.upperBound,
            reply[DHCPServer.Field.clientMAC].elementsEqual(guestMAC)
        else { return }
        guard hostMACs[ip.source].map({ $0.elementsEqual(frame[Packet.sourceMAC]) }) == true else {
            if policy.enforces {
                reportSpoof(
                    "a DHCP reply from another MAC address", protocolNumber: Packet.protocolUDP, now: now,
                    output: &output)
            } else {
                output.toGuest.append(frame)
            }
            return
        }
        if let address = DHCPServer.acknowledgedAddress(in: reply, for: guestMAC) { guestIP = address }
        output.toGuest.append(frame)
    }

    private func networkPayload(_ frame: [UInt8], _ ip: IPv4Packet, now: Date, output: inout Output) {
        if ip.isLaterFragment {
            if !policy.enforces { output.toGuest.append(frame) }
        } else if let tcp = TCPSegment(ip) {
            networkTCP(frame, tcp, now: now, output: &output)
        } else if let udp = UDPDatagram(ip) {
            if udp.sourcePort == Packet.dnsPort, networkDNS(frame, udp, now: now, output: &output) { return }
            let key = FlowKey(
                protocolNumber: Packet.protocolUDP, guestPort: udp.destinationPort, remote: ip.source,
                remotePort: udp.sourcePort)
            networkDatagram(frame, key: key, payload: udp.payload.count, now: now, output: &output)
        } else if isTCPOrUDP(ip) {
            if !policy.enforces { output.toGuest.append(frame) }
        } else if ip.protocolNumber == Packet.protocolICMP {
            networkICMP(frame, ip, now: now, output: &output)
        } else {
            let key = FlowKey(protocolNumber: ip.protocolNumber, guestPort: 0, remote: ip.source, remotePort: 0)
            networkDatagram(frame, key: key, payload: ip.end - ip.payloadOffset, now: now, output: &output)
        }
    }

    /// TCP or UDP without a usable header: one that lies about its length, or a fragment. Judged as plain IP it
    /// would pass on its address alone, so rules drop it; without rules it passes unlogged.
    private func isTCPOrUDP(_ ip: IPv4Packet) -> Bool {
        ip.protocolNumber == Packet.protocolTCP || ip.protocolNumber == Packet.protocolUDP
    }

    private func networkICMP(_ frame: [UInt8], _ ip: IPv4Packet, now: Date, output: inout Output) {
        guard ip.end >= ip.payloadOffset + 8 else { return }
        let type = ip.bytes[ip.payloadOffset]
        if type == ICMPType.echoReply || type == ICMPType.echoRequest {
            networkDatagram(
                frame, key: icmpKey(ip, remote: ip.source), payload: ip.end - ip.payloadOffset - 8, now: now,
                output: &output)
        } else if !policy.isolated, Self.passedICMPErrors.contains(type) || !policy.enforces {
            guard !isFromUnreachableVM(ip.source) else { return }
            output.toGuest.append(frame)
        }
    }

    /// An error from another VM still carries what it chose to send; routers on the internet aren't VMs.
    private func isFromUnreachableVM(_ source: UInt32) -> Bool {
        isLocal(source) && !isHost(source) && !canReachVM(source)
    }

    private func isDHCPRequest(_ frame: [UInt8], _ ip: IPv4Packet) -> Bool {
        guard let udp = UDPDatagram(ip), udp.sourcePort == DHCPServer.clientPort,
            udp.destinationPort == DHCPServer.serverPort,
            ip.destination == IPv4Address.limitedBroadcast.value || ip.destination == subnet.serverAddress.value,
            ip.source == 0 || ip.source == guestIP, DHCPServer.isClientRequest(ip.bytes[udp.payload])
        else { return false }
        let bootp = udp.payload.lowerBound
        let clientMAC = DHCPServer.Field.clientMAC
        guard ip.bytes[(bootp + clientMAC.lowerBound)..<(bootp + clientMAC.upperBound)].elementsEqual(guestMAC)
        else { return false }
        let destination = frame[Packet.destinationMAC]

        return destination.elementsEqual(Packet.broadcastMAC)
            || hostMACs[subnet.serverAddress.value].map { destination.elementsEqual($0) } == true
    }

    private func icmpKey(_ ip: IPv4Packet, remote: UInt32) -> FlowKey {
        let type = ip.bytes[ip.payloadOffset]
        guard type == ICMPType.echoReply || type == ICMPType.echoRequest else {
            return FlowKey(protocolNumber: Packet.protocolICMP, guestPort: 0, remote: remote, remotePort: UInt16(type))
        }
        return FlowKey(
            protocolNumber: Packet.protocolICMP, guestPort: Packet.readUInt16(ip.bytes, at: ip.payloadOffset + 4),
            remote: remote, remotePort: UInt16(ICMPType.echoRequest))
    }

}
