import Foundation

enum DHCPMessage: UInt8 {
    case discover = 1
    case offer = 2
    case request = 3
    case decline = 4
    case ack = 5
    case nak = 6
    case release = 7
    case inform = 8
}

enum DHCPOption {
    static let pad: UInt8 = 0
    static let subnetMask: UInt8 = 1
    static let router: UInt8 = 3
    static let dnsServer: UInt8 = 6
    static let requestedAddress: UInt8 = 50
    static let leaseTime: UInt8 = 51
    static let messageType: UInt8 = 53
    static let serverID: UInt8 = 54
    static let renewalTime: UInt8 = 58
    static let rebindingTime: UInt8 = 59
    static let end: UInt8 = 255
}

package struct DHCPServer {
    package struct Lease: Codable, Equatable, Sendable {
        package var ip: IPv4Address
        package var updatedAt: Date
    }

    package struct Reply {
        package var destinationMAC: [UInt8]
        package var destinationIP: UInt32
        package var payload: [UInt8]
    }

    /// BOOTP's fixed fields, by byte offset (RFC 951 §3).
    package enum Field {
        static let transactionID = 4..<8
        static let flags = 10..<12
        static let clientAddress = 12..<16
        static let yourAddress = 16
        static let serverAddress = 20
        /// The hardware address is 16 bytes, of which an Ethernet address fills the first six.
        package static let clientMAC = 28..<34
        static let clientHardware = 28..<44
        static let magicCookie = 236..<240
    }

    package static let serverPort: UInt16 = 67
    package static let clientPort: UInt16 = 68
    private static let bootRequest: UInt8 = 1
    private static let bootReply: UInt8 = 2
    private static let ethernetHardware: UInt8 = 1
    private static let ethernetAddressLength: UInt8 = 6
    private static let magicCookie: [UInt8] = [99, 130, 83, 99]
    private static let headerSize = 240
    /// The shortest reply a BOOTP client must accept (RFC 1542 §2.1); shorter ones are padded.
    private static let minimumPacketSize = 300
    private static let broadcastFlag: UInt8 = 0x80
    private static let leaseTime: UInt32 = 86_400
    private static let leaseRetention: TimeInterval = 7 * 86_400
    private static let declineHold: TimeInterval = 600

    var subnet: IPv4Subnet
    var serverIP: UInt32
    package var reservations: [String: IPv4Address] = [:]
    package private(set) var leases: [String: Lease] = [:]
    private var declined: [UInt32: Date] = [:]

    package init(subnet: IPv4Subnet, serverIP: UInt32, leases: [String: Lease]) {
        self.subnet = subnet
        self.serverIP = serverIP
        self.leases = leases.filter { subnet.contains($0.value.ip) }
        pruneLeases()
    }

    /// A BOOTP request from an Ethernet client, with DHCP's magic cookie.
    package static func isClientRequest(_ packet: ArraySlice<UInt8>) -> Bool {
        guard packet.count >= headerSize else { return false }
        let start = packet.startIndex
        let cookie = packet[(start + Field.magicCookie.lowerBound)..<(start + Field.magicCookie.upperBound)]
        return packet[start] == bootRequest && packet[start + 1] == ethernetHardware
            && packet[start + 2] == ethernetAddressLength && cookie.elementsEqual(magicCookie)
    }

    package static func clientMAC(of packet: [UInt8]) -> String? {
        guard packet.count >= Field.clientMAC.upperBound else { return nil }
        return MACAddress.string(packet[Field.clientMAC])
    }

    package mutating func pruneLeases() {
        let now = Date()
        leases = leases.filter { mac, lease in
            reservations[mac] != nil || now.timeIntervalSince(lease.updatedAt) < Self.leaseRetention
        }
        declined = declined.filter { now.timeIntervalSince($0.value) < Self.declineHold }
    }

    package mutating func handle(_ packet: [UInt8]) -> Reply? {
        guard Self.isClientRequest(packet[...]), let mac = Self.clientMAC(of: packet) else { return nil }
        let options = Self.parseOptions(Array(packet[Self.headerSize...]))
        guard let type = options[DHCPOption.messageType]?.first.flatMap(DHCPMessage.init(rawValue:)) else { return nil }
        let request = Request(packet: packet, mac: mac, options: options)

        switch type {
        case .discover:
            return offer(to: request)
        case .request:
            return acknowledge(request)
        case .decline:
            decline(request)
            return nil
        case .release:
            if reservations[mac] == nil { leases[mac] = nil }
            return nil
        case .inform:
            return reply(to: request, type: .ack, address: 0)
        case .offer, .ack, .nak:
            return nil
        }
    }

    /// A client's message, with the fields the server decides by.
    private struct Request {
        let packet: [UInt8]
        let mac: String
        let options: [UInt8: [UInt8]]

        var clientIP: UInt32 { Packet.readUInt32(packet, at: Field.clientAddress.lowerBound) }

        /// The address the client asks for, or the one it has.
        var requested: UInt32 { address(in: DHCPOption.requestedAddress) ?? clientIP }

        var serverID: UInt32? { address(in: DHCPOption.serverID) }

        private func address(in option: UInt8) -> UInt32? {
            options[option].flatMap { $0.count == 4 ? Packet.readUInt32($0, at: 0) : nil }
        }
    }

    private func offer(to request: Request) -> Reply? {
        guard let ip = address(for: request.mac, preferring: request.requested) else { return nil }
        return reply(to: request, type: .offer, address: ip)
    }

    /// A request meant for another server is left to it.
    private mutating func acknowledge(_ request: Request) -> Reply? {
        if let server = request.serverID, server != serverIP { return nil }
        guard let ip = address(for: request.mac, preferring: request.requested), ip == request.requested else {
            return reply(to: request, type: .nak, address: 0)
        }

        leases[request.mac] = Lease(ip: IPv4Address(ip), updatedAt: Date())
        return reply(to: request, type: .ack, address: ip)
    }

    /// A declined address is kept from everyone for a while: another host on the network has it.
    private mutating func decline(_ request: Request) {
        guard let declinedAddress = request.options[DHCPOption.requestedAddress], declinedAddress.count == 4 else {
            return
        }

        let ip = IPv4Address(Packet.readUInt32(declinedAddress, at: 0))
        if leases[request.mac]?.ip == ip || reservations[request.mac] == ip {
            declined[ip.value] = Date()
            leases[request.mac] = nil
        }
    }

    private func address(for mac: String, preferring requested: UInt32) -> UInt32? {
        if let reserved = reservations[mac] { return reserved.value }
        let reserved = Set(reservations.values.map(\.value))
        let blocked = subnet.unavailableAddresses.union(declined.keys)
        if let lease = leases[mac], subnet.contains(lease.ip), !blocked.contains(lease.ip.value),
            !reserved.contains(lease.ip.value)
        {
            return lease.ip.value
        }

        let taken = blocked.union(reserved)
            .union(leases.filter { $0.key != mac }.values.map(\.ip.value))
        let pool = subnet.dhcpPool
        if pool.contains(requested), !taken.contains(requested) { return requested }

        return pool.first { !taken.contains($0) }
    }

    private func reply(to request: Request, type: DHCPMessage, address: UInt32) -> Reply {
        let asked = request.packet
        var packet = replyHeader(answering: asked, address: address)
        packet += replyOptions(type: type, address: address)
        if packet.count < Self.minimumPacketSize {
            packet += [UInt8](repeating: 0, count: Self.minimumPacketSize - packet.count)
        }

        let wantsBroadcast = asked[Field.flags.lowerBound] & Self.broadcastFlag != 0
        let clientIP = request.clientIP
        return Reply(
            destinationMAC: wantsBroadcast || type == .nak ? Packet.broadcastMAC : Array(asked[Field.clientMAC]),
            destinationIP: clientIP != 0 && type != .nak ? clientIP : IPv4Address.limitedBroadcast.value,
            payload: packet
        )
    }

    /// The BOOTP header of a reply: the request's identifying fields copied back, with the addresses filled in.
    private func replyHeader(answering asked: [UInt8], address: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: Self.headerSize)
        header[0] = Self.bootReply
        header[1] = Self.ethernetHardware
        header[2] = Self.ethernetAddressLength
        header.replaceSubrange(Field.transactionID, with: asked[Field.transactionID])
        header.replaceSubrange(Field.flags, with: asked[Field.flags])
        header.replaceSubrange(Field.clientAddress, with: asked[Field.clientAddress])
        Packet.writeUInt32(address, into: &header, at: Field.yourAddress)
        Packet.writeUInt32(serverIP, into: &header, at: Field.serverAddress)
        header.replaceSubrange(Field.clientHardware, with: asked[Field.clientHardware])
        header.replaceSubrange(Field.magicCookie, with: Self.magicCookie)
        return header
    }

    /// A NAK names only the server; an offer or ACK adds the network, and a real address its lease times.
    private func replyOptions(type: DHCPMessage, address: UInt32) -> [UInt8] {
        var options: [UInt8] =
            [DHCPOption.messageType, 1, type.rawValue, DHCPOption.serverID, 4] + Packet.bytes(serverIP)
        if type != .nak {
            let gateway = subnet.gateway.value
            options += [DHCPOption.subnetMask, 4] + Packet.bytes(subnet.mask.value)
            options += [DHCPOption.router, 4] + Packet.bytes(gateway)
            options += [DHCPOption.dnsServer, 4] + Packet.bytes(gateway)
            if address != 0 {
                options += [DHCPOption.leaseTime, 4] + Packet.bytes(Self.leaseTime)
                options += [DHCPOption.renewalTime, 4] + Packet.bytes(Self.leaseTime / 2)
                options += [DHCPOption.rebindingTime, 4] + Packet.bytes(Self.leaseTime / 8 * 7)
            }
        }
        options.append(DHCPOption.end)
        return options
    }

    package static func acknowledgedAddress(in packet: [UInt8], for mac: [UInt8]) -> UInt32? {
        guard packet.count >= headerSize, packet[0] == bootReply, packet[Field.clientMAC].elementsEqual(mac),
            packet[Field.magicCookie].elementsEqual(magicCookie),
            parseOptions(Array(packet[headerSize...]))[DHCPOption.messageType]?.first == DHCPMessage.ack.rawValue
        else { return nil }
        let address = Packet.readUInt32(packet, at: Field.yourAddress)
        return address == 0 ? nil : address
    }

    private static func parseOptions(_ bytes: [UInt8]) -> [UInt8: [UInt8]] {
        var options: [UInt8: [UInt8]] = [:]
        var index = 0

        while index < bytes.count {
            let code = bytes[index]
            if code == DHCPOption.end { break }
            if code == DHCPOption.pad {
                index += 1
                continue
            }
            guard index + 1 < bytes.count else { break }
            let length = Int(bytes[index + 1])
            guard index + 2 + length <= bytes.count else { break }
            options[code] = Array(bytes[(index + 2)..<(index + 2 + length)])
            index += 2 + length
        }

        return options
    }
}
