import Foundation
import HangarSupport
import HangarTraffic
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct VMConfigTests {

    @Test func policyDefaultsAndNetworkRequirement() throws {
        let config = VMConfig(
            os: .linux, cpuCount: 2, memorySize: 4 * ByteSize.gib, display: .linuxDefault,
            network: NetworkSettings(mode: .nat, macAddress: "02:00:00:00:00:01"))

        #expect(config.traffic.mode == .monitor)
        #expect(!config.traffic.allowsHost)
        #expect(!config.traffic.allowsVMs)
        #expect(!config.clipboard)
        #expect(!config.traffic.enforces)
        #expect(throws: Never.self) { try config.traffic.checkRunnable(on: .nat) }
        #expect(throws: (any Error).self) { try TrafficPolicy(mode: .allowlist).checkRunnable(on: .nat) }
        #expect(throws: (any Error).self) { try TrafficPolicy(mode: .blocklist).checkRunnable(on: .nat) }
        #expect(throws: (any Error).self) { try TrafficPolicy(mode: .monitor, isolated: true).checkRunnable(on: .nat) }
        #expect(throws: (any Error).self) { try TrafficPolicy(mode: .monitor, isolated: true).checkRunnable(on: .none) }
        #expect(throws: Never.self) { try TrafficPolicy(mode: .blocklist).checkRunnable(on: .managed) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                TrafficPolicy.self, from: Data(#"{"mode":"allowlist","allowed":["github.com"]}"#.utf8))
        }
    }

    @Test func everySettingIsAFieldConfigJSONMayHave() {
        let config = VMConfig(
            os: .linux, cpuCount: 2, memorySize: 4 * ByteSize.gib, display: .linuxDefault,
            network: NetworkSettings(mode: .nat, macAddress: "02:00:00:00:00:01"))

        let settings = Set(Mirror(reflecting: config).children.compactMap(\.label))

        #expect(settings == VMConfig.keys)
    }

    @Test func aConfigWithAFieldHangarDoesntKnowIsRefused() throws {
        let bundle = try TestVM.make(.linux)
        var fields = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.configURL)) as? [String: Any])
        fields["colour"] = "red"
        try JSONSerialization.data(withJSONObject: fields).write(to: bundle.configURL)

        let refusal = failureMessage { _ = try bundle.loadConfig() }

        #expect(refusal == "\(bundle.configURL.path) has a field Hangar doesn't know: 'colour'.")
    }

    @Test func aSavedConfigReadsBackWithItsOptionalSettings() throws {
        let bundle = try TestVM.make(.linux)

        let saved = try bundle.updateConfig {
            $0.sshUser = "dev"
            $0.image = "debian"
            $0.cloudInit = "#cloud-config"
            $0.setup = ["uname -a"]
            $0.setupRanAt = Date(timeIntervalSince1970: 1_800_000_000)
            $0.usesNestedVirtualization = true
        }

        #expect(try bundle.loadConfig() == saved)
    }
}
