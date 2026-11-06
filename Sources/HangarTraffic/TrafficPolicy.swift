import Foundation
import HangarSupport

package struct TrafficPolicy: Codable, Hashable, Sendable {
    package static let maximumRules = 1000

    package enum Mode: String, Codable, CaseIterable, Sendable {
        case off
        case monitor
        case allowlist
        case blocklist

        package var displayName: String {
            switch self {
            case .off: "Off"
            case .monitor: "Monitor"
            case .allowlist: "Allow List"
            case .blocklist: "Block List"
            }
        }
    }

    package var mode: Mode
    package var allowed: [String]
    package var blocked: [String]
    package var allowsHost: Bool
    package var allowsVMs: Bool
    package var allowsLocalNetwork: Bool
    package var allowsQUIC: Bool
    package var allowsUDP: Bool
    package var isolated: Bool

    package init(
        mode: Mode = .monitor, allowed: [String] = [], blocked: [String] = [], allowsHost: Bool = false,
        allowsVMs: Bool = false, allowsLocalNetwork: Bool = false, allowsQUIC: Bool = false, allowsUDP: Bool = true,
        isolated: Bool = false
    ) {
        self.mode = mode
        self.allowed = allowed
        self.blocked = blocked
        self.allowsHost = allowsHost
        self.allowsVMs = allowsVMs
        self.allowsLocalNetwork = allowsLocalNetwork
        self.allowsQUIC = allowsQUIC
        self.allowsUDP = allowsUDP
        self.isolated = isolated
    }

    package var watches: Bool { mode != .off || isolated }

    package var enforces: Bool { isolated || mode == .allowlist || mode == .blocklist }

    package mutating func allow(_ hosts: [String]) throws {
        let rules = try TrafficRule.normalize(hosts)
        blocked.removeAll { rules.contains($0) }
        allowed = try TrafficRule.normalize(allowed + rules)
        try Self.checkCount(allowed.count + blocked.count)
    }

    package mutating func block(_ hosts: [String]) throws {
        let rules = try TrafficRule.normalize(hosts)
        allowed.removeAll { rules.contains($0) }
        blocked = try TrafficRule.normalize(blocked + rules)
        try Self.checkCount(allowed.count + blocked.count)
    }

    package static func checkCount(_ count: Int) throws {
        guard count <= maximumRules else {
            throw HangarError("A VM can have at most \(maximumRules) traffic rules.")
        }
    }

    package mutating func remove(_ hosts: [String]) throws {
        let rules = hosts.map { (try? TrafficRule($0).description) ?? $0 }
        if let missing = rules.first(where: { !allowed.contains($0) && !blocked.contains($0) }) {
            throw HangarError("There is no rule '\(missing)'.")
        }
        allowed.removeAll { rules.contains($0) }
        blocked.removeAll { rules.contains($0) }
    }

    package func validate() throws {
        try Self.checkCount(allowed.count + blocked.count)
        for rule in allowed + blocked {
            _ = try TrafficRule(rule)
        }
    }
}
