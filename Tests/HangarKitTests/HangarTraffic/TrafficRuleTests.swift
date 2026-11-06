import HangarKit
import HangarPackets
import HangarTraffic
import Testing

struct TrafficRuleTests {
    /// Rules match names as the parsers give them, lowercased; the inspector's tests cover a guest's capitals.
    @Test func domainsIncludeSubdomainsAndWildcardsOnlySubdomains() throws {
        let domain = try TrafficRule("GitHub.com.")
        let wildcard = try TrafficRule("*.npmjs.org")

        #expect(domain.description == "github.com")
        #expect(domain.matches(name: "github.com"))
        #expect(domain.matches(name: "api.github.com"))
        #expect(!domain.matches(name: "evilgithub.com"))
        #expect(!domain.matches(name: "github.com.evil.net"))
        #expect(wildcard.matches(name: "registry.npmjs.org"))
        #expect(!wildcard.matches(name: "npmjs.org"))
        #expect(domain.matches(name: "api.github.com."))
        #expect(!domain.matches(name: "x.\u{0301}github.com"))
        #expect(!domain.matches(name: "ithub.com"))
    }

    @Test func addressesAndNetworks() throws {
        let network = try TrafficRule("140.82.112.0/20")

        #expect(network.matches(address: ipv4("140.82.121.4").value))
        #expect(!(network.matches(address: ipv4("140.82.128.1").value)))
        #expect(!network.matches(name: "140.82.121.4"))
        #expect(try TrafficRule("1.2.3.4").description == "1.2.3.4")
        #expect(try TrafficRule("0.0.0.0/0").matches(address: 0x0808_0808))
    }

    @Test(arguments: ["", "http://github.com", "github..com", "-bad.com", "1.2.3.4/33", "10.0.0.0/x", "a b.com", "*."])
    func rejectsMalformedRules(_ text: String) {
        #expect(throws: (any Error).self) { try TrafficRule(text) }
    }

    @Test func aHostIsEitherAllowedOrBlocked() throws {
        var policy = TrafficPolicy()

        try policy.allow(["GitHub.com", "pypi.org"])
        try policy.block(["github.com"])

        #expect(policy.allowed == ["pypi.org"])
        #expect(policy.blocked == ["github.com"])

        try policy.allow(["github.com"])

        #expect(policy.allowed == ["pypi.org", "github.com"])
        #expect(policy.blocked.isEmpty)

        try policy.remove(["PyPI.org"])

        #expect(policy.allowed == ["github.com"])
        #expect(throws: (any Error).self) { try policy.remove(["npmjs.org"]) }
        #expect(throws: (any Error).self) { try policy.allow(["not a host"]) }
        #expect(policy.allowed == ["github.com"])
    }

    @Test func rulesThatDoNotParseStopThePolicyUntilRemoved() throws {
        var policy = TrafficPolicy(mode: .blocklist, blocked: ["evil .example", "tracker.example"])
        #expect(throws: (any Error).self) { try policy.checkRunnable(on: .managed) }

        try policy.remove(["evil .example"])

        #expect(policy.blocked == ["tracker.example"])
        #expect(throws: Never.self) { try policy.checkRunnable(on: .managed) }
    }

    @Test func rulesTellWhetherAHostIsAllowedOrBlocked() {
        let rules = TrafficRules(
            TrafficPolicy(mode: .allowlist, allowed: ["github.com", "10.0.0.0/8"], blocked: ["*.evil.example"]))

        #expect(rules.verdict(for: "api.github.com") == .allowed)
        #expect(rules.verdict(for: "10.1.2.3") == .allowed)
        #expect(rules.verdict(for: "cdn.evil.example") == .blocked)
        #expect(rules.verdict(for: "CDN.Evil.Example") == .blocked)
        #expect(rules.verdict(for: "evil.example") == nil)
        #expect(rules.verdict(for: "pypi.org") == nil)
    }
}
