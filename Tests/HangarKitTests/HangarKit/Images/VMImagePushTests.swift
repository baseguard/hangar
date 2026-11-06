import Foundation
import HangarDisks
import HangarSupport
import HangarTraffic
import Testing
import Virtualization

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct VMImagePushTests {
    @Test func pushedImagesComeBackByteForByte() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make()
        let disk = try Data(contentsOf: bundle.diskURL)

        let digest = try await registry.push(bundle)
        let cached = try await registry.pull(digest)

        #expect(try Data(contentsOf: cached.disk) == disk)
        #expect(try Data(contentsOf: cached.nvram) == Data("nvram".utf8))
        #expect(cached.config.macOS?.version == "27.0.1")
        #expect(cached.config.macOS?.minimumMemorySize == 4 << 30)

        let again = try await registry.pull(digest)
        #expect(again.folder == cached.folder)
    }

    @Test func anExportedMacOSVMKeepsItsHardwareModelAndAccounts() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make()
        try bundle.updateConfig { $0.sshUser = "dev" }
        let source = try bundle.loadConfig()
        let disk = try Data(contentsOf: bundle.diskURL)
        let reference = try registry.reference("my-mac:1.0")

        let digest = try await VMImage.push(bundle, to: [reference], credentials: nil) { _ in }
        let cached = try await registry.pull(digest)

        let details = try #require(cached.config.macOS)
        #expect(details.version == nil && details.build == nil)
        #expect(details.hardwareModel == source.hardwareModel)
        #expect(details.minimumCPUCount == VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        #expect(cached.config.diskSize == UInt64(disk.count))
        #expect(cached.config.account == "dev")
        #expect(try Data(contentsOf: cached.disk) == disk)

        let copy = try await VMImage.createVM(
            name: "copy", from: cached, source: "test",
            options: CreateOptions(cpuCount: 2, memorySize: 4 << 30, diskSize: cached.config.diskSize)
        ) { _ in }
        let config = try copy.loadConfig()
        #expect(config.hardwareModel == source.hardwareModel)
        #expect(config.cpuCount == 2)
        #expect(config.machineIdentifier != source.machineIdentifier)
    }

    @Test func aMacOSThatWasSetUpAlreadyCreatesNoNewAccount() throws {
        let exported = VMImage.Config(
            os: .macOS, diskSize: 1 << 20, account: nil,
            macOS: try MacImage.exportedDetails(of: try TestVM.make().loadConfig()))

        #expect(!exported.takesNewAccount)

        #expect(
            failureMessage {
                try VMImage.check(
                    exported, options: CreateOptions(diskSize: 1 << 20),
                    macAccount: MacProvisioning(fullName: "Dev", username: "dev", password: "secret"),
                    linuxAccount: nil, userData: nil)
            } == "This image is a macOS that was set up already and keeps its own accounts; leave out --user.")
        try VMImage.check(
            exported, options: CreateOptions(diskSize: 1 << 20), macAccount: nil, linuxAccount: nil, userData: nil)
    }

    @Test func linuxImagesLeaveTheirSeedBehindAndGetANewOne() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)
        try bundle.updateConfig {
            $0.sshUser = "dev"
            $0.network = NetworkSettings(mode: .nat, macAddress: "02:11:22:33:44:55", ipAddress: "10.99.0.77")
            $0.sharedFolders = [SharedFolder(name: "secret-share", path: "/Users/someone/secret-share")]
            $0.traffic.mode = .allowlist
            $0.isoPath = "/Users/someone/secret.iso"
        }
        let seed = Data("instance-id: old, password hash".utf8)
        try seed.write(to: bundle.cloudInitURL)
        let disk = try Data(contentsOf: bundle.diskURL)

        let digest = try await registry.push(bundle)

        let manifest = try registry.manifest(digest)
        #expect(manifest.layers.map(\.mediaType) == [VMImage.configType, VMImage.nvramType, VMImage.diskType])
        let stubBlob = try #require(registry.stored("blobs/\(manifest.config.digest)"))
        let stub = try #require(try JSONSerialization.jsonObject(with: stubBlob) as? [String: Any])
        #expect(Set(stub.keys) == ["architecture", "os", "rootfs"] && stub["os"] as? String == "linux")
        let configBlob = try #require(registry.stored("blobs/\(manifest.layers[0].digest)"))
        let keys = try #require(try JSONSerialization.jsonObject(with: configBlob) as? [String: Any]).keys
        #expect(Set(keys) == ["os", "diskSize", "account"])
        for secret in [seed]
            + ["02:11:22:33:44:55", "10.99.0.77", "secret-share", "secret.iso", "allowlist"].map({ Data($0.utf8) })
        {
            #expect(!registry.storedValues.contains { $0.range(of: secret) != nil })
        }

        let cached = try await registry.pull(digest)
        #expect(try Data(contentsOf: cached.disk) == disk)
        #expect(cached.config == VMImage.Config(os: .linux, diskSize: 3 << 20, account: "dev", macOS: nil))

        let copy = try await VMImage.createVM(
            name: "copy", from: cached, source: "test", options: CreateOptions(diskSize: 1 << 20)
        ) { _ in }
        let config = try copy.loadConfig()
        #expect(config.os == .linux)
        #expect(config.sshUser == "dev")
        #expect(config.hardwareModel == nil)
        let source = try bundle.loadConfig()
        #expect(config.machineIdentifier != nil && config.machineIdentifier != source.machineIdentifier)
        let files = try ISOImage.files(in: Data(contentsOf: copy.cloudInitURL))
        #expect(String(decoding: try #require(files["meta-data"]), as: UTF8.self).contains("local-hostname: \"copy\""))
        #expect(try Data(contentsOf: copy.diskURL) == disk)
    }

    @Test func partsThatAppearTwiceAreWrittenInBothPlaces() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux, diskSize: 600 << 20)
        let first = try FileHandle(forReadingFrom: bundle.diskURL).read(upToCount: 2 << 20) ?? Data()
        let handle = try FileHandle(forWritingTo: bundle.diskURL)
        try handle.seek(toOffset: 256 << 20)
        try handle.write(contentsOf: first)
        try handle.close()
        let disk = try Data(contentsOf: bundle.diskURL)

        let digest = try await registry.push(bundle)

        let manifest = try registry.manifest(digest)
        let parts = manifest.layers.filter { $0.mediaType == VMImage.diskType }
        #expect(parts.count == 2 && Set(parts.map(\.digest)).count == 1)
        #expect(try Data(contentsOf: try await registry.pull(digest).disk) == disk)

        var forged = manifest
        let second = try #require(forged.layers.lastIndex { $0.mediaType == VMImage.diskType })
        forged.layers[second].annotations?[VMImage.plainDigestKey] = VMImage.digest(of: Data("other".utf8))
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }
    }

    @Test func windowsImagesKeepRemoteDesktopOff() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.windows)
        try bundle.updateConfig { $0.remoteDesktop = false }

        let cached = try await registry.pull(try await registry.push(bundle))

        #expect(cached.config.remoteDesktop == false)

        let copy = try await VMImage.createVM(
            name: "copy", from: cached, source: "test", options: CreateOptions(diskSize: 1 << 20)
        ) { _ in }
        #expect(try copy.loadConfig().remoteDesktop == false)
        #expect(try copy.loadConfig().audio == false)
    }

    @Test func snapshotsArePushedWithTheirOwnSettingsWhileTheVMRuns() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)
        let snapshot = VMSnapshot(url: bundle.snapshotsURL.appendingPathComponent("clean", isDirectory: true))
        try FileManager.default.createDirectory(at: snapshot.url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle.diskURL, to: snapshot.diskURL)
        try FileManager.default.copyItem(at: bundle.nvramURL, to: snapshot.nvramURL)
        var settings = try bundle.loadConfig()
        settings.sshUser = "snap"
        try JSON.write(settings, to: snapshot.configURL)
        try bundle.updateConfig { $0.sshUser = "live" }

        let running = try VMLibrary.lockStopped(bundle)
        defer { running.unlock() }

        #expect(
            await failureMessage { try await registry.push(bundle) } == "'\(bundle.name)' is running. Stop it first.")
        let digest = try await registry.push(bundle, snapshot: snapshot)
        #expect(try await registry.pull(digest).config.account == "snap")
    }

    @Test func onlyVMsThatFinishedTheirFirstStartArePushed() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)

        let notStarted =
            "'\(bundle.name)' hasn't started yet, so its accounts aren't set up on the disk; start it once, then push it."
        try bundle.updateConfig { $0.firstStartedAt = nil }
        #expect(await failureMessage { try await registry.push(bundle) } == notStarted)

        try bundle.updateConfig {
            $0.firstStartedAt = Date()
            $0.provisioning = MacProvisioning(fullName: "Dev", username: "dev", password: "secret")
        }
        #expect(await failureMessage { try await registry.push(bundle) } == notStarted)

        try bundle.updateConfig {
            $0.provisioning = nil
            $0.sshUser = "-oProxyCommand=x"
        }
        #expect(
            await failureMessage { try await registry.push(bundle) }
                == "'\(bundle.name)''s account '-oProxyCommand=x' can't go into an image.")

        let mac = try TestVM.make(.macOS, named: "mac")
        try mac.updateConfig { $0.firstStartedAt = nil }
        #expect(
            await failureMessage {
                try await VMImage.push(mac, to: [try registry.reference("mac:1")], credentials: nil) { _ in }
            } == "'mac' hasn't started yet, so its accounts aren't set up on the disk; start it once, then push it.")
    }

    @Test func hangarsVanillaImageIsPushedBeforeItsFirstStart() async throws {
        let registry = try await StubRegistry()
        let vanilla = try TestVM.make(.macOS, named: "image-vanilla")
        try vanilla.updateConfig { $0.firstStartedAt = nil }

        let digest = try await registry.push(vanilla, tag: "vanilla")

        let cached = try await registry.pull(digest)
        #expect(cached.config.macOS?.version == "27.0.1")
    }

    @Test func chunkedUploadsArriveWhole() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)
        let disk = try Data(contentsOf: bundle.diskURL)

        let digest = try await VMImage.push(
            bundle, to: [try registry.reference("ci:1.0")], credentials: nil,
            uploadChunkSize: 256
        ) { _ in }

        #expect(registry.pieces > 4)
        let cached = try await VMImage.pull(try registry.reference("ci@\(digest)"), named: "ci") { _ in }
        #expect(try Data(contentsOf: cached.disk) == disk)

        #expect(throws: (any Error).self) { try VMImage.uploadChunkSize(megabytes: 4) }
        #expect(throws: (any Error).self) { try VMImage.uploadChunkSize(megabytes: 513) }
        #expect(try VMImage.uploadChunkSize(megabytes: 0) == 0)
    }

    @Test func chunkedUploadsStopAtAnotherHostOrAShortAccept() async throws {
        let bundle = try TestVM.make(.linux)
        try FileManager.default.removeItem(at: bundle.diskURL)
        try SparseFile.create(at: bundle.diskURL, size: 1 << 20)
        let otherPort = try await StubRegistry()
        let noLocation = "did not say where to upload."
        let short = "didn't take all of an upload piece; try again with a larger --chunk-size, or 0."
        let spoils: [(spoil: (StubRegistry) -> Void, refusal: String)] = [
            ({ $0.movePieces(to: "evil.example") }, noLocation), ({ $0.movePieces(to: otherPort.host) }, noLocation),
            ({ $0.acceptShort() }, short),
        ]
        defer { #expect(otherPort.pieces == 0) }

        for (spoil, refusal) in spoils {
            let registry = try await StubRegistry()
            spoil(registry)

            #expect(
                await failureMessage {
                    try await VMImage.push(
                        bundle, to: [try registry.reference("ci:1.0")], credentials: nil,
                        uploadChunkSize: 2
                    ) { _ in }
                } == "\(registry.host) \(refusal)")

            #expect(registry.pieces == 1)
        }
    }
}
