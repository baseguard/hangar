import Foundation
import HangarPackets

package struct TrafficRules: Sendable {
    package let allowed: [TrafficRule]
    package let blocked: [TrafficRule]

    /// A rule that doesn't parse can't be here: `TrafficPolicy.checkRunnable` refuses the policy before a VM starts.
    package init(_ policy: TrafficPolicy) {
        allowed = policy.allowed.compactMap { try? TrafficRule($0) }
        blocked = policy.blocked.compactMap { try? TrafficRule($0) }
    }

    /// For a host typed or shown outside the packet path, so it is lowercased here like the rules.
    package func verdict(for host: String) -> TrafficEvent.Verdict? {
        let name = host.lowercased()
        let address = IPv4Address(name)?.value
        func matches(_ rule: TrafficRule) -> Bool {
            address.map(rule.matches(address:)) ?? rule.matches(name: name)
        }
        if blocked.contains(where: matches) { return .blocked }
        if allowed.contains(where: matches) { return .allowed }
        return nil
    }
}
