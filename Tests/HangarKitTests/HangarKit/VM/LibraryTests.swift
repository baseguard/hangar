import Foundation
import HangarDisks
import HangarPackets
import HangarSecrets
import HangarSupport
import HangarTraffic
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct LibraryTests {
    private let home: URL

    init() throws {
        home = try #require(HangarPaths.homeOverride)
    }

    private func makeVM(_ name: String, ip: String? = nil) async throws -> VMBundle {
        try await VMLibrary.create(name: name) { staging in
            try SparseFile.create(at: staging.diskURL, size: 1 << 20)
            let network = NetworkSettings(
                mode: .managed, macAddress: VMConfig.randomMACAddress(),
                ipAddress: ip ?? VMLibrary.allocateIPAddress())
            try staging.saveConfig(
                VMConfig(os: .linux, cpuCount: 1, memorySize: 1 << 30, display: .linuxDefault, network: network))
        }
    }

    @Test func createGivesEachVMItsOwnAddressAndCleansUp() async throws {
        #expect(HangarPaths.home.path == home.path)

        let first = try await makeVM("one")
        let second = try await makeVM("two")

        #expect(try first.loadConfig().network.ipAddress == "192.168.72.10")
        #expect(try second.loadConfig().network.ipAddress == "192.168.72.11")
        #expect(VMLibrary.all().map(\.name) == ["one", "two"])
        #expect(VMLibrary.stagingDirectories.isEmpty)
        for file in [HangarPaths.vms, first.url, first.diskURL, first.configURL] {
            var info = stat()
            #expect(stat(file.path, &info) == 0)
            #expect(info.st_mode & 0o077 == 0, "\(file.lastPathComponent) is readable by others")
        }
    }

    @Test func abandonedStagingIsRemovedButLockedStagingIsKept() throws {
        let abandoned = HangarPaths.vms.appendingPathComponent(".creating-old-0000", isDirectory: true)
        let active = HangarPaths.vms.appendingPathComponent(".creating-new-1111", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let lock = FileLock(url: VMLibrary.stagingLock(for: active))
        #expect(try lock.tryLock(.exclusive))

        VMLibrary.removeAbandonedStaging()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        lock.unlock()
    }

    @Test func runningVMCannotBeRenamedOrDeleted() async throws {
        let bundle = try await makeVM("busy")
        let runLock = FileLock(url: bundle.lockURL)
        #expect(try runLock.tryLock(.exclusive))

        #expect(throws: (any Error).self) { try VMLibrary.delete(bundle) }
        #expect(throws: (any Error).self) { try VMLibrary.rename(bundle, to: "other") }

        runLock.unlock()
        try VMLibrary.rename(bundle, to: "other")
        #expect(VMLibrary.all().map(\.name) == ["other"])
        try VMLibrary.delete(VMLibrary.bundle(named: "other"))
        #expect(VMLibrary.all().isEmpty)
    }

    @Test func renamingCanChangeOnlyTheCase() async throws {
        let bundle = try await makeVM("web")
        _ = try await makeVM("other")

        try VMLibrary.rename(bundle, to: "Web")

        #expect(VMLibrary.all().map(\.name) == ["other", "Web"])
        #expect(throws: (any Error).self) { try VMLibrary.rename(VMLibrary.bundle(named: "Web"), to: "OTHER") }
    }

    @Test func growingADiskNeedsTheDiskToExist() async throws {
        let bundle = try await makeVM("disk")

        try bundle.resizeDisk(to: 2 << 20)
        #expect(bundle.diskSize == 2 << 20)
        #expect(throws: (any Error).self) { try bundle.resizeDisk(to: 1 << 20) }

        try FileManager.default.removeItem(at: bundle.diskURL)
        #expect(throws: (any Error).self) { try bundle.resizeDisk(to: 4 << 20) }
        #expect(!FileManager.default.fileExists(atPath: bundle.diskURL.path))
    }

    @Test func deletingLeavesNothingBehind() async throws {
        let bundle = try await makeVM("gone")
        try FileManager.default.createDirectory(
            at: HangarPaths.vms.appendingPathComponent(".deleting-old-0000"),
            withIntermediateDirectories: false)

        try VMLibrary.delete(bundle)

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: HangarPaths.vms.path).filter {
                $0 != ".deleting-old-0000"
            }.isEmpty)

        VMLibrary.removeAbandonedStaging()
        #expect(try FileManager.default.contentsOfDirectory(atPath: HangarPaths.vms.path).isEmpty)
    }

    @Test func busyStoppedVMIsNotReportedAsRunning() async throws {
        let bundle = try await makeVM("idle")
        let runLock = FileLock(url: bundle.lockURL)
        #expect(try runLock.tryLock(.exclusive))
        try runLock.write(JSON.encoder.encode(RunInfo(pid: getpid(), host: .cli)))
        #expect(bundle.isRunning)

        runLock.unlock()
        try VMLibrary.withStoppedVM(bundle) {
            #expect(!bundle.isRunning)
        }
    }

    @Test func cloningNeedsTheWholeVM() async throws {
        let bundle = try await makeVM("partial")

        await #expect(throws: (any Error).self) { try await VMLibrary.clone(bundle, as: "copy") }
        #expect(!VMLibrary.exists("copy"))

        try Data("nvram".utf8).write(to: bundle.nvramURL)
        let copy = try await VMLibrary.clone(bundle, as: "copy")
        #expect(try copy.loadConfig().network.macAddress != bundle.loadConfig().network.macAddress)
    }

    @Test func aFolderCopiedInFinderIsATwinUntilItIsMadeSeparate() async throws {
        let original = try await makeVM("deb")
        try original.updateConfig { $0.secrets = SecretSettings() }
        let other = try await makeVM("other")
        let copy = VMBundle(url: HangarPaths.vms.appendingPathComponent("deb copy", isDirectory: true))
        try FileManager.default.copyItem(at: original.url, to: copy.url)
        let originalConfig = try original.loadConfig()

        let twinOfOriginal = VMLibrary.twin(of: original, config: originalConfig)
        let error = #expect(throws: HangarError.self) { try VMLibrary.checkNotTwin(copy, config: copy.loadConfig()) }
        let separated = try VMLibrary.separate(copy, as: "deb-copy")

        #expect(twinOfOriginal?.name == "deb copy")
        #expect(error?.message.contains("'deb copy' and 'deb'") == true)
        #expect(VMLibrary.twin(of: original, config: originalConfig) == nil)
        #expect(VMLibrary.twin(of: other, config: try other.loadConfig()) == nil)
        let separatedConfig = try separated.loadConfig()
        #expect(VMLibrary.twin(of: separated, config: separatedConfig) == nil)
        #expect(separatedConfig.network.ipAddress != originalConfig.network.ipAddress)
        #expect(separatedConfig.secrets == nil)
        #expect(try original.loadConfig() == originalConfig)
        #expect(VMLibrary.all().map(\.name) == ["deb", "deb-copy", "other"])
    }

    @Test func deletingAVMKeepsItsKeychainItemsWhileAnotherVMMayBeItsCopy() async throws {
        let original = try await makeVM("deb")
        let config = try original.loadConfig()
        let other = try await makeVM("other")
        let aloneReason = VMLibrary.reasonToKeepKeychainItems(of: original, config: config)
        let broken = HangarPaths.vms.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        try Data("{".utf8).write(to: broken.appendingPathComponent("config.json"))

        let brokenReason = VMLibrary.reasonToKeepKeychainItems(of: original, config: config)
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.copyItem(at: original.url, to: HangarPaths.vms.appendingPathComponent("deb copy"))
        let twinReason = VMLibrary.reasonToKeepKeychainItems(of: original, config: config)

        #expect(aloneReason == nil)
        #expect(brokenReason?.contains("'broken' can't be read") == true)
        #expect(twinReason == "'deb copy', a copy of it, uses them too.")
        #expect(VMLibrary.reasonToKeepKeychainItems(of: other, config: try other.loadConfig()) == nil)
    }

    @Test func changingTheSubnetMovesReservedAddresses() async throws {
        let moved = try await makeVM("moved")
        let kept = try await makeVM("kept", ip: "10.99.0.50")
        let natVM = try await makeVM("nat")
        var config = try natVM.loadConfig()
        config.network = NetworkSettings(mode: .nat, macAddress: config.network.macAddress)
        try natVM.saveConfig(config)
        let broken = HangarPaths.vms.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        try Data("{".utf8).write(to: broken.appendingPathComponent("config.json"))

        let skipped = try SharedNetwork.changeSubnet(to: try #require(IPv4Subnet("10.99.0.1/24")))

        #expect(skipped == ["broken"])
        #expect(try moved.loadConfig().network.ipAddress == "10.99.0.10")
        #expect(try kept.loadConfig().network.ipAddress == "10.99.0.50")
        #expect(try natVM.loadConfig().network.ipAddress == nil)
        #expect(SharedNetwork.subnet.description == "10.99.0.1/24")
    }

    @Test func theSubnetStaysWhileAVMUsesTheNetwork() throws {
        try HangarPaths.createDirectory(SharedNetwork.directory)
        let user = FileLock(url: SharedNetwork.usersLockURL)
        try user.lock(.shared)

        #expect(throws: (any Error).self) {
            try SharedNetwork.changeSubnet(to: try #require(IPv4Subnet("10.98.0.1/24")))
        }

        user.unlock()
        try SharedNetwork.changeSubnet(to: try #require(IPv4Subnet("10.98.0.1/24")))
        #expect(SharedNetwork.subnet.description == "10.98.0.1/24")
    }

    @Test func concurrentConfigChangesAreAllKept() async throws {
        let bundle = try await makeVM("shared")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? bundle.updateConfig { $0.traffic.allowed.append("host\(index).example") }
                }
            }
        }

        #expect(try bundle.loadConfig().traffic.allowed.count == 20)
    }

    @Test func configsMissingAFieldAreRefused() async throws {
        let bundle = try await makeVM("partial")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.configURL)) as? [String: Any] ?? [:]
        json["traffic"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: bundle.configURL)

        var message = ""
        do { _ = try bundle.loadConfig() } catch { message = error.localizedDescription }

        #expect(message.contains("missing 'traffic'. Restore that file or delete the VM."))
    }

    @Test func namesAreValidated() async throws {
        _ = try await makeVM("taken")

        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "taken") }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "has space") }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: String(repeating: "a", count: 41)) }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "web_1") }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "web.1") }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "-web") }
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "web-") }
        #expect(throws: Never.self) { try VMLibrary.validate(name: "web-1") }
        #expect(throws: Never.self) { try VMLibrary.validate(name: "w") }
    }

    @Test func aFolderBeingCreatedStaysLockedAndLeavesNothingBehind() async throws {
        var lockWasHeld = false
        var survivedCleanup = false

        let bundle = try await VMLibrary.create(name: "fresh") { staging in
            lockWasHeld = FileLock.isHeld(VMLibrary.stagingLock(for: staging.url))
            VMLibrary.removeAbandonedStaging()
            survivedCleanup = FileManager.default.fileExists(atPath: staging.url.path)
        }

        #expect(lockWasHeld)
        #expect(survivedCleanup)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: HangarPaths.vms.path) == [bundle.url.lastPathComponent])
    }

    @Test func aCancelledCreateLeavesNoVM() async throws {
        let creating = Task {
            try await VMLibrary.create(name: "late-cancel") { staging in
                try SparseFile.create(at: staging.diskURL, size: 1 << 20)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let result = await creating.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!VMLibrary.exists("late-cancel"))
    }

    @Test func reusingADiskFileClearsWhatWasInIt() throws {
        let disk = home.appendingPathComponent("reused.img")
        try Data(repeating: 0xAB, count: 4096).write(to: disk)

        try SparseFile.create(at: disk, size: 8192, truncateExisting: true)

        #expect(try Data(contentsOf: disk) == Data(count: 8192))
    }
}
