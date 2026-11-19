import Foundation
import Testing

@testable import HangarSecrets

struct SecretRuleTests {
    /// `hangar secret set --header` alone used to save an empty host list, which the VM then refused.
    @Test func settingASecretAgainKeepsWhatIsNotGiven() {
        let header = SecretRule.Header(name: "Authorization", format: "Bearer %s")
        let existing = SecretRule(name: "TOKEN", hosts: ["api.github.com"], placeholder: "p1", header: nil)

        let withHeader = SecretRule.toSave(
            name: "TOKEN", hosts: [], header: header, basicUser: nil, replacing: existing)
        let withHosts = SecretRule.toSave(
            name: "TOKEN", hosts: ["Other.example"], header: nil, basicUser: nil, replacing: withHeader)
        let fresh = SecretRule.toSave(
            name: "TOKEN", hosts: ["api.github.com"], header: nil, basicUser: nil, replacing: nil)

        #expect(withHeader.hosts == ["api.github.com"])
        #expect(withHeader.header == header)
        #expect(withHeader.placeholder == "p1")
        #expect(withHosts.hosts == ["other.example"])
        #expect(withHosts.header == header)
        #expect(fresh.hosts == ["api.github.com"])
        #expect(fresh.header == nil)
    }

    /// A rule sends its value in a header or as Basic credentials; giving one drops the other.
    @Test func aBasicUserGivenReplacesTheHeaderAndKeepsTheRest() {
        let header = SecretRule.Header(name: "Authorization", format: "Bearer %s")
        let existing = SecretRule(name: "TOKEN", hosts: ["github.com"], placeholder: "p1", header: header)

        let basic = SecretRule.toSave(
            name: "TOKEN", hosts: [], header: nil, basicUser: "x-access-token", replacing: existing)
        let hostsOnly = SecretRule.toSave(
            name: "TOKEN", hosts: ["*.github.com"], header: nil, basicUser: nil, replacing: basic)

        #expect(basic.header == nil)
        #expect(basic.basicUser == "x-access-token")
        #expect(basic.hosts == ["github.com"])
        #expect(hostsOnly.basicUser == "x-access-token")
        #expect(hostsOnly.places == ["headers", "signs in as x-access-token"])
        #expect(throws: (any Error).self) {
            try SecretRule.validate(sending: SecretRule(name: "T", hosts: [], header: header, basicUser: "me"))
        }
    }

    @Test(arguments: ["", "user:name", "user\r\nX-Evil: 1"])
    func aBasicUserThatWouldBreakTheCredentialsIsRefused(user: String) {
        #expect(throws: (any Error).self) { try SecretRule.validate(basicUser: user) }
    }

    @Test func aWildcardHostTakesTheHostsUnderItButNotItself() throws {
        let rule = SecretRule(name: "TOKEN", hosts: ["*.GitHub.com"])

        #expect(rule.applies(to: "uploads.github.com"))
        #expect(rule.applies(to: "a.b.github.com"))
        #expect(!rule.applies(to: "github.com"))
        #expect(!rule.applies(to: "evilgithub.com"))
        try SecretRule.validate(host: "*.github.com")
        #expect(throws: (any Error).self) { try SecretRule.validate(host: "*.com") }
        #expect(throws: (any Error).self) { try SecretRule.validate(host: "a.*.github.com") }
    }

    /// The same line is in hangar_host_commands' tests.
    @Test func theTrustLineIsWrittenTheWayTheAgentReadsIt() {
        let rules = [
            SecretRule(name: "GITHUB_TOKEN", hosts: ["api.github.com"], placeholder: "abc123"),
            SecretRule(name: "NODE_ENV_X", hosts: ["example.com"], placeholder: "Z9"),
        ]

        let line = TrustCommand.line(authority: [0x30, 0x03, 0x02, 0x01, 0x01], rules: rules)

        #expect(line == "trust 3003020101 GITHUB_TOKEN=abc123 NODE_ENV_X=Z9\n")
        #expect(TrustCommand.line(authority: nil, rules: []) == "trust -\n")
    }

    @Test func placeholdersAreLettersAndDigitsOnly() {
        let placeholder = SecretRule.newPlaceholder()

        #expect(placeholder.count == 38)
        #expect(placeholder.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    @Test(arguments: ["github_token", "1TOKEN", "TOKEN-X", ""])
    func aNameTheAgentWouldRefuseIsRefused(name: String) {
        #expect(throws: (any Error).self) { try SecretRule.validate(name: name) }
    }

    @Test(arguments: [
        "PATH", "BASH_ENV", "NODE_OPTIONS", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "COMSPEC", "PERL5LIB", "PERLLIB",
        "RUBYLIB", "NODE_PATH", "CLASSPATH", "PYTHONSTARTUP", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "GCONV_PATH",
    ])
    func aVariableTheGuestsShellsRelyOnCantNameASecret(name: String) {
        #expect(throws: (any Error).self) { try SecretRule.validate(name: name) }
    }

    @Test(arguments: ["GITHUB_TOKEN", "LDAP_TOKEN", "PATH_TOKEN", "MY_HOME"])
    func aNameThatOnlyLooksLikeOneTheGuestReliesOnIsAccepted(name: String) {
        #expect(throws: Never.self) { try SecretRule.validate(name: name) }
    }

    @Test func aValueTooShortToMaskSafelyIsRefused() {
        #expect(throws: (any Error).self) { try SecretRule.validate(value: "abc123") }
        #expect(throws: Never.self) { try SecretRule.validate(value: "abcd1234") }
    }

    @Test func aValueWithALineBreakOrAFormatWithoutTheValueIsRefused() {
        #expect(throws: (any Error).self) { try SecretRule.validate(value: "token\r\nX-Evil: 1") }
        #expect(throws: (any Error).self) {
            try SecretRule.validate(header: SecretRule.Header(name: "Authorization", format: "Bearer"))
        }
        #expect(throws: Never.self) {
            try SecretRule.validate(header: SecretRule.Header(name: "Authorization", format: "Bearer %s"))
        }
    }

    /// With `*.example.com` the guest chooses the hosts, so it could otherwise fill the proxy's memory.
    @Test func theProxyKeepsAFewCertificatesAndDropsTheOldFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = ["a": now.addingTimeInterval(-90_000), "b": now.addingTimeInterval(-60), "c": now]

        SecretsProxyServer.State.makeRoom(in: &cache, limit: 3, madeAt: { $0 }, now: now)
        #expect(Set(cache.keys) == ["b", "c"])

        cache["d"] = now
        SecretsProxyServer.State.makeRoom(in: &cache, limit: 3, madeAt: { $0 }, now: now)
        #expect(Set(cache.keys) == ["c", "d"])
    }

    @Test func aCertificateTheProxyMadeIsMadeAgainAfterADay() {
        let madeAt = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(SecretAuthority.isFresh(madeAt: madeAt, now: madeAt.addingTimeInterval(3600)))
        #expect(!SecretAuthority.isFresh(madeAt: madeAt, now: madeAt.addingTimeInterval(25 * 3600)))
        #expect(!SecretAuthority.isFresh(madeAt: madeAt, now: madeAt.addingTimeInterval(-60)))
    }
}
