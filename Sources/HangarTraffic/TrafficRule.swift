import Foundation
import HangarPackets
import HangarSupport

package enum TrafficRule: Hashable, Sendable {
    case domain(String, subdomainsOnly: Bool)
    case network(IPv4Address, prefixLength: Int)

    /// A DNS name's limit (RFC 1035); the labels' is in the pattern below.
    static let longestName = 253

    package init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()

        if let address = IPv4Address(value) {
            self = .network(address, prefixLength: 32)
            return
        }

        if value.contains("/") {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let address = IPv4Address(String(parts[0])), let length = Int(parts[1]),
                (0...32).contains(length)
            else {
                throw HangarError("'\(text)' is not an address like 1.2.3.4 or a network like 10.0.0.0/8.")
            }
            self = .network(address, prefixLength: length)
            return
        }

        let subdomainsOnly = value.hasPrefix("*.")
        let name = subdomainsOnly ? String(value.dropFirst(2)) : value
        let normalized = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard normalized.count <= Self.longestName,
            normalized.wholeMatch(
                of: /[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?(?:\.[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?)*/) != nil
        else {
            throw HangarError(
                "'\(text)' is not a domain like github.com or *.github.com, or an address like 10.0.0.0/8.")
        }
        self = .domain(normalized, subdomainsOnly: subdomainsOnly)
    }

    package var description: String {
        switch self {
        case .domain(let name, let subdomainsOnly): subdomainsOnly ? "*.\(name)" : name
        case .network(let address, 32): address.description
        case .network(let address, let length): "\(address)/\(length)"
        }
    }

    /// Compares bytes, with no string built per call: every parser gives the guest's names lowercased, and a rule is
    /// lowercased when it is read. `github.com.` and `github.com` name the same host; the trailing dot only marks the
    /// name as complete.
    package func matches(name: String) -> Bool {
        guard case .domain(let domain, let subdomainsOnly) = self else { return false }
        let host = name.utf8.last == UInt8(ascii: ".") ? name.utf8.dropLast() : name.utf8[...]
        let suffix = domain.utf8
        guard host.count >= suffix.count, host.suffix(suffix.count).elementsEqual(suffix) else { return false }
        let rest = host.dropLast(suffix.count)
        return rest.isEmpty ? !subdomainsOnly : rest.last == UInt8(ascii: ".")
    }

    package func matches(address: UInt32) -> Bool {
        guard case .network(let network, let length) = self else { return false }
        let mask = length == 0 ? 0 : UInt32.max << UInt32(32 - length)
        return address & mask == network.value & mask
    }

    /// A network rule that names only addresses in `subnet`, like one VM or a few on Hangar's network.
    func isWithin(_ subnet: IPv4Subnet) -> Bool {
        guard case .network(let network, let length) = self else { return false }
        return length >= subnet.prefixLength && subnet.contains(network)
    }

    package static func normalize(_ texts: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for text in texts {
            let rule = try TrafficRule(text).description
            if seen.insert(rule).inserted { result.append(rule) }
        }
        return result
    }
}
