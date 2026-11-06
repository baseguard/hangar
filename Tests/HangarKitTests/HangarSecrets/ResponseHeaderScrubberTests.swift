import Foundation
import HangarSecrets
import Testing

struct ResponseHeaderScrubberTests {
    private let github = SecretRule(
        name: "GITHUB_TOKEN", hosts: ["api.github.com"], placeholder: "hangarGITHUB0123456789")
    private let openai = SecretRule(
        name: "OPENAI_API_KEY", hosts: ["api.openai.com"], placeholder: "hangarOPENAI0123456789")

    private func scrubber(for host: String = "api.github.com") -> ResponseHeaderScrubber {
        ResponseHeaderScrubber(
            serverName: host, rules: [github, openai],
            values: ["GITHUB_TOKEN": "ghp_real_value", "OPENAI_API_KEY": "sk-openai-real"])
    }

    @Test func aHeaderGetsThePlaceholderBack() {
        var scrubber = scrubber()

        let location = scrubber.scrub(headerValue: "/next?t=ghp_real_value")

        #expect(location == "/next?t=hangarGITHUB0123456789")
        #expect(scrubber.masked == ["GITHUB_TOKEN"])
    }

    @Test func aPercentEncodedValueIsCaughtToo() {
        let rule = SecretRule(name: "KEY", hosts: ["api.github.com"], placeholder: "hangarKEY")
        var scrubber = ResponseHeaderScrubber(
            serverName: "api.github.com", rules: [rule], values: ["KEY": "a/b c+d=e"])

        #expect(scrubber.scrub(headerValue: "/x?k=a%2Fb%20c%2Bd%3De") == "/x?k=hangarKEY")
    }

    @Test func anotherHostsValueIsLeftAlone() {
        var scrubber = scrubber(for: "api.github.com")

        #expect(scrubber.scrub(headerValue: "sk-openai-real") == "sk-openai-real")
        #expect(scrubber.masked.isEmpty)
    }
}
