import Foundation

package struct IPv4Address: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    package var value: UInt32

    package init(_ value: UInt32) {
        self.value = value
    }

    package init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    package init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        self.value = value
    }

    package init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let address = IPv4Address(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid IPv4 address \(string)"))
        }
        self = address
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// 255.255.255.255: every host on the link.
    package static let limitedBroadcast = IPv4Address(0xffff_ffff)

    /// 224.0.0.0/4.
    package var isMulticast: Bool { value & 0xf000_0000 == 0xe000_0000 }

    /// 224.0.0.0/24: the groups routers never forward.
    package var isLinkLocalMulticast: Bool { value & 0xffff_ff00 == 0xe000_0000 }

    package var description: String {
        "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    package var inAddr: in_addr {
        in_addr(s_addr: value.bigEndian)
    }

    package static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }
}
