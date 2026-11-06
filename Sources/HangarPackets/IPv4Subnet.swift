import Foundation

package struct IPv4Subnet: Hashable, Codable, CustomStringConvertible, Sendable {
    package var gateway: IPv4Address
    package var prefixLength: Int

    package static let `default` = IPv4Subnet(gateway: IPv4Address(192, 168, 72, 1), prefixLength: 24)
    package static let prefixLengths = 16...29

    package init(gateway: IPv4Address, prefixLength: Int) {
        self.gateway = gateway
        self.prefixLength = prefixLength
    }

    package init?(_ string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2, let gateway = IPv4Address(String(parts[0])), let length = Int(parts[1]) else {
            return nil
        }

        let subnet = IPv4Subnet(gateway: gateway, prefixLength: length)
        guard subnet.isValid else { return nil }
        self = subnet
    }

    private enum CodingKeys: String, CodingKey {
        case gateway, prefixLength
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let subnet = IPv4Subnet(
            gateway: try container.decode(IPv4Address.self, forKey: .gateway),
            prefixLength: try container.decode(Int.self, forKey: .prefixLength))
        guard subnet.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .prefixLength, in: container,
                debugDescription: "\(subnet) is not a usable subnet.")
        }
        self = subnet
    }

    package var isValid: Bool {
        Self.prefixLengths.contains(prefixLength) && gateway > network && gateway < broadcast
    }

    package var mask: IPv4Address {
        IPv4Address(UInt32.max << UInt32(32 - prefixLength))
    }

    package var network: IPv4Address {
        IPv4Address(gateway.value & mask.value)
    }

    package var broadcast: IPv4Address {
        IPv4Address(network.value | ~mask.value)
    }

    package func contains(_ address: IPv4Address) -> Bool {
        address.value & mask.value == network.value
    }

    package var serverAddress: IPv4Address {
        gateway.value + 1 < broadcast.value ? IPv4Address(gateway.value + 1) : IPv4Address(gateway.value - 1)
    }

    package var unavailableAddresses: Set<UInt32> {
        [network.value, gateway.value, serverAddress.value, broadcast.value]
    }

    /// A quarter of the hosts, between 2 and 50, at the top of the subnet.
    private static let largestPool: UInt32 = 50
    private static let smallestPool: UInt32 = 2
    private static let poolShare: UInt32 = 4
    /// Reservations start past the first few addresses, which stay free for the gateway, the server and the like.
    private static let firstReservableOffset: UInt32 = 10

    package var dhcpPool: ClosedRange<UInt32> {
        let hosts = broadcast.value - network.value - 1
        let size = min(Self.largestPool, max(hosts / Self.poolShare, Self.smallestPool))
        return (broadcast.value - size)...(broadcast.value - 1)
    }

    package var reservableRange: ClosedRange<UInt32> {
        let last = dhcpPool.lowerBound - 1
        let first = network.value + Self.firstReservableOffset
        return first <= last ? first...last : (network.value + 1)...last
    }

    package var description: String {
        "\(gateway)/\(prefixLength)"
    }
}
