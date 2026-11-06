@testable import HangarPackets

enum TrafficSamples {
    static func dnsQuery(_ name: String, id: UInt16 = 0x1234, type: UInt16 = DNSMessage.typeA) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        bytes += encode(name) + [UInt8(type >> 8), UInt8(type & 0xff), 0, 1]
        return bytes
    }

    static func dnsAnswer(to query: [UInt8], addresses: [String], alias: String? = nil) -> [UInt8] {
        var bytes = query
        bytes[2] = 0x81
        bytes[3] = 0x80
        var owner: [UInt8] = [0xc0, 12]
        var count = 0
        if let alias {
            let target = encode(alias)
            let offset = bytes.count + 12
            bytes += [0xc0, 12, 0, 5, 0, 1, 0, 0, 0x0e, 0x10, 0, UInt8(target.count)] + target
            owner = [0xc0 | UInt8(offset >> 8), UInt8(offset & 0xff)]
            count += 1
        }
        for address in addresses {
            bytes += owner + [0, 1, 0, 1, 0, 0, 0x0e, 0x10, 0, 4] + Packet.bytes(ipv4(address).value)
            count += 1
        }
        bytes[7] = UInt8(count)
        return bytes
    }

    static func clientHello(serverName: String?, protocols: [String] = []) -> [UInt8] {
        var extensions: [UInt8] = [0, 0x0a, 0, 4, 0, 2, 0, 0x1d]
        if let serverName {
            let name = Array(serverName.utf8)
            extensions += [0, 0] + u16(name.count + 5) + u16(name.count + 3) + [0] + u16(name.count) + name
        }
        if !protocols.isEmpty {
            let list = protocols.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
            extensions += [0, 16] + u16(list.count + 2) + u16(list.count) + list
        }
        let body: [UInt8] =
            [3, 3] + [UInt8](repeating: 7, count: 32) + [0, 0, 2, 0x13, 0x01, 1, 0] + u16(extensions.count) + extensions
        let handshake: [UInt8] = [1, 0] + u16(body.count) + body
        return [0x16, 3, 1] + u16(handshake.count) + handshake
    }

    static func splitRecords(_ hello: [UInt8], at split: Int) -> [UInt8] {
        let handshake = Array(hello.dropFirst(5))
        return [0x16, 3, 1] + u16(split) + handshake.prefix(split) + [0x16, 3, 1] + u16(handshake.count - split)
            + handshake.dropFirst(split)
    }

    private static func encode(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    private static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
}
