import Foundation

/// The hosts a VM's secrets are for: a name like `api.github.com` is that host alone, and `*.github.com` is every
/// host under github.com, at any depth, but not github.com itself, as in traffic rules. Names are compared
/// lowercased, as every parser gives them.
package struct SecretHosts: Sendable {
    private static let wildcardPrefix = "*."

    /// The names without a wildcard, looked up at once; on the packet path most names are checked against these.
    private let exactNames: Set<String>
    /// `.github.com` for `*.github.com`, made once: `hasSuffix` with a `String` is several times faster than with
    /// the `Substring` `dropFirst` gives, and QUIC to a host with a secret is checked per packet.
    private let parentSuffixes: [String]

    package init(_ patterns: some Sequence<String>) {
        let lowercased = patterns.map { $0.lowercased() }
        exactNames = Set(lowercased.filter { !Self.isWildcard($0) })
        parentSuffixes = lowercased.filter(Self.isWildcard).map(Self.parentSuffix)
    }

    package var isEmpty: Bool { exactNames.isEmpty && parentSuffixes.isEmpty }

    package func contains(_ name: String) -> Bool {
        exactNames.contains(name) || parentSuffixes.contains { Self.isUnder(name, parentSuffix: $0) }
    }

    /// One pattern against one lowercased name, for a check that doesn't keep the set.
    package static func matches(_ pattern: String, _ name: String) -> Bool {
        let lowercased = pattern.lowercased()
        guard isWildcard(lowercased) else { return lowercased == name }
        return isUnder(name, parentSuffix: parentSuffix(lowercased))
    }

    /// The one rule for a wildcard: `*.github.com` takes the names ending in `.github.com`.
    private static func isUnder(_ name: String, parentSuffix: String) -> Bool {
        name.hasSuffix(parentSuffix)
    }

    private static func parentSuffix(_ wildcard: String) -> String {
        String(wildcard.dropFirst())
    }

    /// The domain a certificate's name constraint names for a pattern: `github.com` for `*.github.com`. A constraint
    /// also allows the names under it, so the proxy, not the constraint, keeps github.com itself out.
    package static func constrainedDomain(of pattern: String) -> String {
        pattern.hasPrefix(wildcardPrefix) ? String(pattern.dropFirst(wildcardPrefix.count)) : pattern
    }

    package static func isWildcard(_ pattern: String) -> Bool {
        pattern.hasPrefix(wildcardPrefix)
    }
}
