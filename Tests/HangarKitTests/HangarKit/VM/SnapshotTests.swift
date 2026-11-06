import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct SnapshotTests {
    private let bundle: VMBundle

    init() throws {
        let home = try #require(HangarPaths.homeOverride)
        bundle = VMBundle(url: home.appendingPathComponent("vms/dev", isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try Data("disk one".utf8).write(to: bundle.diskURL)
        try Data("nvram one".utf8).write(to: bundle.nvramURL)
        var config = VMConfig(
            os: .macOS, cpuCount: 2, memorySize: 1 << 30, display: .macDefault,
            network: NetworkSettings(mode: .managed, macAddress: "02:00:00:00:00:01"))
        config.provisioning = MacProvisioning(fullName: "Admin", username: "admin", password: "secret")
        try bundle.saveConfig(config)
    }

    /// Where a restore keeps the VM's own file while it puts the snapshot's in place.
    private func setAside(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(Snapshots.setAsidePrefix + file.lastPathComponent)
    }

    @Test func configFilesKeepNoPasswords() throws {
        let text = try String(contentsOf: bundle.configURL, encoding: .utf8)
        #expect(!text.contains("secret"))
        let provisioning = try #require(try bundle.loadConfig().provisioning)
        #expect(provisioning.password.isEmpty)
        #expect(provisioning.username == "admin")
        #expect(UUID(uuidString: provisioning.passwordItem) != nil)
    }

    @Test func snapshotsKeepNoPasswords() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "fresh")
        let copied = try JSON.read(VMConfig.self, from: snapshot.configURL)

        #expect(copied.provisioning == nil)
        #expect(copied.cpuCount == 2)
        #expect(try bundle.loadConfig().provisioning != nil)
    }

    @Test func restoreBringsBackTheDiskAndNVRAM() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "clean")
        try Data("disk two".utf8).write(to: bundle.diskURL)
        try Data("nvram two".utf8).write(to: bundle.nvramURL)

        try Snapshots.restore(snapshot, to: bundle)

        #expect(try String(contentsOf: bundle.diskURL, encoding: .utf8) == "disk one")
        #expect(try String(contentsOf: bundle.nvramURL, encoding: .utf8) == "nvram one")
    }

    @Test func aRestoreThatCantPlaceTheNVRAMPutsTheVMsOwnDiskBack() throws {
        let stagedDisk = bundle.url.appendingPathComponent(".restoring-disk.img")
        try Data("snapshot disk".utf8).write(to: stagedDisk)
        let missingNVRAM = bundle.url.appendingPathComponent(".restoring-nvram.bin")
        let replacements = [
            Snapshots.Replacement(staged: stagedDisk, file: bundle.diskURL),
            Snapshots.Replacement(staged: missingNVRAM, file: bundle.nvramURL),
        ]

        let failure = failureMessage { try Snapshots.replaceTogether(replacements) }

        #expect(failure?.hasPrefix("Could not restore \(bundle.nvramURL.path)") == true)
        #expect(try String(contentsOf: bundle.diskURL, encoding: .utf8) == "disk one")
        #expect(try String(contentsOf: bundle.nvramURL, encoding: .utf8) == "nvram one")
        let files = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(!files.contains { $0.hasPrefix(".") })
    }

    @Test func aRestoreThatStoppedAfterPlacingTheDiskPutsBackTheVMsOwnDiskAndNVRAM() throws {
        try FileManager.default.moveItem(at: bundle.diskURL, to: setAside(bundle.diskURL))
        try FileManager.default.moveItem(at: bundle.nvramURL, to: setAside(bundle.nvramURL))
        try Data("snapshot disk".utf8).write(to: bundle.diskURL)

        Snapshots.putBackSetAsideFiles(in: bundle)

        #expect(try String(contentsOf: bundle.diskURL, encoding: .utf8) == "disk one")
        #expect(try String(contentsOf: bundle.nvramURL, encoding: .utf8) == "nvram one")
        let files = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(!files.contains { $0.hasPrefix(".") })
    }

    @Test func aRestoreThatPlacedEveryFileKeepsTheSnapshotsDiskAndNVRAM() throws {
        try FileManager.default.moveItem(at: bundle.diskURL, to: setAside(bundle.diskURL))
        try FileManager.default.moveItem(at: bundle.nvramURL, to: setAside(bundle.nvramURL))
        try Data("snapshot disk".utf8).write(to: bundle.diskURL)
        try Data("snapshot nvram".utf8).write(to: bundle.nvramURL)

        Snapshots.putBackSetAsideFiles(in: bundle)

        #expect(try String(contentsOf: bundle.diskURL, encoding: .utf8) == "snapshot disk")
        #expect(try String(contentsOf: bundle.nvramURL, encoding: .utf8) == "snapshot nvram")
        let files = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
        #expect(!files.contains { $0.hasPrefix(".") })
    }

    @Test func aSnapshotWithUnreadableSettingsLeavesTheVMAsItWas() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "broken")
        try Data("changed disk".utf8).write(to: bundle.diskURL)
        try Data("{".utf8).write(to: snapshot.configURL)

        let refusal = failureMessage { try Snapshots.restore(snapshot, to: bundle) }

        #expect(refusal?.hasPrefix("Could not read the settings saved with snapshot 'broken': ") == true)
        #expect(try String(contentsOf: bundle.diskURL, encoding: .utf8) == "changed disk")
    }

    @Test func failedSnapshotLeavesNothingBehind() async throws {
        try FileManager.default.removeItem(at: bundle.diskURL)

        await #expect(throws: HangarError.self) { try await Snapshots.take(of: bundle, name: "broken") }

        #expect(bundle.snapshots.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.snapshotsURL.path)
        #expect(leftovers.isEmpty)
    }

    @Test func restoreDropsLeftovers() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "clean")
        let leftover = bundle.url.appendingPathComponent(".restoring-disk.img")
        try Data("half".utf8).write(to: leftover)
        try FileManager.default.createDirectory(
            at: bundle.snapshotsURL.appendingPathComponent(".taking-crashed"),
            withIntermediateDirectories: false)

        try Snapshots.restore(snapshot, to: bundle)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.snapshotsURL.path) == ["clean"])
    }

    @Test func namesAreCheckedAndUnique() async throws {
        await #expect(throws: (any Error).self) { try await Snapshots.take(of: bundle, name: "two words") }
        await #expect(throws: (any Error).self) { try await Snapshots.take(of: bundle, name: "../escape") }

        _ = try await Snapshots.take(of: bundle, name: "first")
        await #expect(throws: (any Error).self) { try await Snapshots.take(of: bundle, name: "first") }
        #expect(bundle.snapshots.map(\.name) == ["first"])
        #expect(throws: (any Error).self) { try bundle.snapshot(named: "missing") }

        try Snapshots.delete(try bundle.snapshot(named: "first"))
        #expect(bundle.snapshots.isEmpty)
    }

    @Test func renamingKeepsTheSnapshotAndRefusesATakenName() async throws {
        let clean = try await Snapshots.take(of: bundle, name: "clean")
        try await Snapshots.take(of: bundle, name: "base")

        let renamed = try Snapshots.rename(clean, of: bundle, to: "first")
        let recased = try Snapshots.rename(renamed, of: bundle, to: "First")

        #expect(throws: (any Error).self) { try Snapshots.rename(recased, of: bundle, to: "base") }
        #expect(bundle.snapshots.map(\.name).sorted() == ["First", "base"])
        #expect(try Data(contentsOf: recased.diskURL) == Data("disk one".utf8))
    }

    @Test func cloningASnapshotUsesItsDiskAndSettings() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "base")
        try Data("disk two".utf8).write(to: bundle.diskURL)
        var changed = try bundle.loadConfig()
        changed.cpuCount = 8
        try bundle.saveConfig(changed)
        let running = FileLock(url: bundle.lockURL)
        #expect(try running.tryLock(.exclusive))
        defer { running.unlock() }

        let clone = try await VMLibrary.clone(snapshot, as: "derived")

        #expect(try String(contentsOf: clone.diskURL, encoding: .utf8) == "disk one")
        #expect(try String(contentsOf: clone.nvramURL, encoding: .utf8) == "nvram one")
        let config = try clone.loadConfig()
        #expect(config.cpuCount == 2)
        #expect(config.provisioning == nil)
        #expect(config.network.macAddress != "02:00:00:00:00:01")
    }

    @Test func cloningASnapshotGivesTheCloudInitSeedANewName() async throws {
        let web = VMBundle(url: HangarPaths.vms.appendingPathComponent("web", isDirectory: true))
        try FileManager.default.createDirectory(at: web.url, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: web.diskURL)
        try Data("nvram".utf8).write(to: web.nvramURL)
        try web.saveConfig(
            VMConfig(
                os: .linux, cpuCount: 2, memorySize: 1 << 30, display: .linuxDefault,
                network: NetworkSettings(mode: .managed, macAddress: "02:00:00:00:00:02")))
        try CloudInit.writeSeed(
            account: CloudInitAccount(username: "dev", password: "secret"), userData: nil, hostname: "web",
            to: web.cloudInitURL)
        let snapshot = try await Snapshots.take(of: web, name: "base")

        let clone = try await VMLibrary.clone(snapshot, as: "copy")

        let metaData = try #require(try ISOImage.files(in: Data(contentsOf: clone.cloudInitURL))["meta-data"])
        #expect(String(decoding: metaData, as: UTF8.self).contains(#"local-hostname: "copy""#))
    }

    @Test func restoreRefusesARunningVM() async throws {
        let snapshot = try await Snapshots.take(of: bundle, name: "clean")
        let running = FileLock(url: bundle.lockURL)
        #expect(try running.tryLock(.exclusive))
        defer { running.unlock() }

        #expect(throws: (any Error).self) { try Snapshots.restore(snapshot, to: bundle) }
    }

    @Test func onlyExportsThatStoppedLeaveTheirCopiesToBeCleanedUp() async throws {
        let stale = bundle.snapshotsURL.appendingPathComponent(Snapshots.exportingPrefix + "stale", isDirectory: true)
        let running = bundle.snapshotsURL.appendingPathComponent(
            Snapshots.exportingPrefix + "running", isDirectory: true)
        for folder in [stale, running] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let inUse = FileLock(url: Snapshots.exportLock(in: running))
        try inUse.lock(.exclusive)
        defer { inUse.unlock() }

        _ = try await Snapshots.take(of: bundle, name: "clean")

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(bundle.snapshots.map(\.name) == ["clean"])
    }

    @Test func restoringASnapshotFromBeforeTheFirstStartForgetsTheStart() async throws {
        try bundle.updateConfig { $0.firstStartedAt = nil }
        let snapshot = try await Snapshots.take(of: bundle, name: "fresh")
        try bundle.updateConfig { $0.firstStartedAt = Date() }

        try Snapshots.restore(snapshot, to: bundle)

        #expect(try bundle.loadConfig().firstStartedAt == nil)
    }
}
