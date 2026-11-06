import Foundation
import HangarSecrets
import Testing

struct RequestRewriterTests {
    private let github = SecretRule(
        name: "GITHUB_TOKEN", hosts: ["api.github.com"], placeholder: "hangarGITHUB")
    private let openai = SecretRule(
        name: "OPENAI_API_KEY", hosts: ["api.openai.com"], placeholder: "hangarOPENAI")

    private func rewriter(_ rules: [SecretRule]? = nil, for host: String = "api.github.com") -> RequestRewriter {
        RequestRewriter(
            serverName: host, rules: rules ?? [github, openai],
            values: ["GITHUB_TOKEN": "ghp_real_value", "OPENAI_API_KEY": "sk real/key"])
    }

    private func head(
        _ uri: String = "/user", host: String = "api.github.com", fields: [RequestHead.Field] = []
    ) -> RequestHead {
        RequestHead(method: "GET", uri: uri, fields: [RequestHead.Field("Host", host)] + fields)
    }

    private func forwarded(_ verdict: RequestRewriter.Verdict) throws -> RequestHead {
        guard case .forward(let head, _) = verdict else {
            Issue.record("refused: \(verdict)")
            throw CancellationError()
        }
        return head
    }

    private func status(_ verdict: RequestRewriter.Verdict) -> Int? {
        guard case .refuse(let refusal) = verdict else { return nil }
        return refusal.status
    }

    @Test func thePlaceholderInAHeaderBecomesTheValue() throws {
        let verdict = rewriter().rewrite(head(fields: [RequestHead.Field("Authorization", "Bearer hangarGITHUB")]))

        let sent = try forwarded(verdict)

        #expect(sent.fields.contains(RequestHead.Field("Authorization", "Bearer ghp_real_value")))
        #expect(verdict == .forward(sent, used: ["GITHUB_TOKEN"]))
    }

    @Test func theURLAndOtherHeadersGoAsTheGuestSentThem() throws {
        let request = head("/user?token=hangarGITHUB", fields: [RequestHead.Field("Accept-Encoding", "gzip, br")])

        let sent = try forwarded(rewriter().rewrite(request))

        #expect(sent == request)
    }

    @Test func anotherHostsPlaceholderIsRefusedAndNeverSent() {
        let verdict = rewriter().rewrite(head(fields: [RequestHead.Field("X-Key", "hangarOPENAI")]))

        #expect(status(verdict) == 403)
    }

    @Test func aRequestNamingAnotherHostIsRefused() {
        #expect(status(rewriter().rewrite(head(host: "evil.example"))) == 421)
        #expect(status(rewriter().rewrite(head("https://evil.example/user"))) == 421)
        #expect(status(rewriter().rewrite(RequestHead(method: "GET", uri: "/", fields: []))) == 421)
    }

    @Test func anotherHostsPlaceholderInTheURLIsRefused() {
        #expect(status(rewriter().rewrite(head("/user?token=hangarOPENAI"))) == 403)
    }

    @Test func aRulesOwnHeaderIsSetOnEveryRequest() throws {
        let rule = SecretRule(
            name: "GITHUB_TOKEN", hosts: ["api.github.com"], placeholder: "hangarGITHUB",
            header: SecretRule.Header(name: "Authorization", format: "token %s"))

        let sent = try forwarded(
            rewriter([rule]).rewrite(head(fields: [RequestHead.Field("authorization", "anything")])))

        #expect(
            sent.fields.filter { $0.name.lowercased() == "authorization" } == [
                RequestHead.Field("Authorization", "token ghp_real_value")
            ])
    }

    @Test func tunnelsUpgradesAndDoubleLengthsAreRefused() {
        let connect = RequestHead(
            method: "CONNECT", uri: "api.github.com:443", fields: [RequestHead.Field("Host", "api.github.com")])
        let upgrade = head(fields: [RequestHead.Field("Upgrade", "websocket")])
        let lengths = head(fields: [
            RequestHead.Field("Content-Length", "1"), RequestHead.Field("Transfer-Encoding", "chunked"),
        ])

        #expect(status(rewriter().rewrite(connect)) == 405)
        #expect(status(rewriter().rewrite(upgrade)) == 501)
        #expect(status(rewriter().rewrite(lengths)) == 400)
    }
}
