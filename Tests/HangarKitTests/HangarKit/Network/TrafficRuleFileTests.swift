import Foundation
import HangarKit
import HangarSupport
import HangarTraffic
import Testing

struct TrafficRuleFileTests {
    @Test func ruleFilesCarryTheRulesButNeverTheIsolation() throws {
        let source = TrafficPolicy(
            mode: .allowlist, allowed: ["github.com", "*.apple.com"], blocked: ["ads.example"],
            allowsVMs: true, allowsUDP: false, isolated: true)
        let file = try TrafficRuleFile.decode(try TrafficRuleFile(source).encoded())

        var target = TrafficPolicy(mode: .monitor, blocked: ["old.example"], isolated: true)
        try target.apply(file)
        #expect(target.mode == .allowlist)
        #expect(target.allowed == ["github.com", "*.apple.com"])
        #expect(target.blocked == ["ads.example"])
        #expect(target.allowsVMs && !target.allowsUDP)
        #expect(target.isolated)

        var open = TrafficPolicy()
        try open.apply(file)
        #expect(!open.isolated)
        #expect(!(String(decoding: try file.encoded(), as: UTF8.self).contains("isolated")))
    }

    @Test func brokenRuleFilesAreRefused() async throws {
        var file = TrafficRuleFile(TrafficPolicy(mode: .blocklist, blocked: ["ads.example"]))

        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(Data(#"{"mode":"blocklist"}"#.utf8)) }
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(Data(count: TrafficRuleFile.sizeLimit + 1)) }

        file.allowed = ["ads.example"]
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(try file.encoded()) }
        file.allowed = ["not a host"]
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(try file.encoded()) }

        await #expect(throws: (any Error).self) {
            try await TrafficRuleFile.download(from: "http://example.com/rules.json")
        }
        await #expect(throws: (any Error).self) { try await TrafficRuleFile.download(from: "rules.json") }
    }

    @Test func aVMHasAtMostAThousandRules() throws {
        let hosts = (1...TrafficPolicy.maximumRules).map { "host\($0).example" }
        var policy = TrafficPolicy(mode: .allowlist)
        try policy.allow(hosts)

        #expect(throws: (any Error).self) { try policy.block(["one-more.example"]) }
        #expect(policy.allowed.count == TrafficPolicy.maximumRules)

        var file = TrafficRuleFile(policy)
        file.blocked = ["one-more.example"]
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(try file.encoded()) }

        #expect(throws: (any Error).self) {
            try TrafficPolicy(mode: .allowlist, allowed: hosts + ["one-more.example"]).checkRunnable(on: .managed)
        }
    }

    @Test func ruleFileErrorsNameTheKeyAndCountsAreDeduplicated() throws {
        let missing = Data(
            #"{"mode":"blocklist","allowed":[],"blocked":[],"allowsHost":false,"allowsVMs":false,"allowsLocalNetwork":false,"allowsQUIC":false}"#
                .utf8)

        let error = #expect(throws: HangarError.self) { try TrafficRuleFile.decode(missing) }
        #expect(error?.message.contains("'allowsUDP'") == true)

        var file = TrafficRuleFile(TrafficPolicy(mode: .blocklist))
        file.blocked = ["ads.example", "ADS.example", "ads.example"]
        #expect(try TrafficRuleFile.decode(try file.encoded()).blocked == ["ads.example"])
    }

    @Test func rulesFilesWithFieldsHangarDoesntKnowAreRefused() throws {
        let exported = String(
            decoding: try TrafficRuleFile(TrafficPolicy(mode: .allowlist, allowed: ["github.com"])).encoded(),
            as: UTF8.self)
        _ = try TrafficRuleFile.decode(Data(exported.utf8))

        let isolating = exported.replacingOccurrences(of: #""mode""#, with: #""isolated" : true, "mode""#)
        #expect(throws: (any Error).self) { try TrafficRuleFile.decode(Data(isolating.utf8)) }
    }
}
