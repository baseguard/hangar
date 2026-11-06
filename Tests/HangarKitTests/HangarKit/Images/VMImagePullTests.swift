import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct VMImagePullTests {
    private func partialFile(of part: VMImage.Descriptor, inImage digest: String) -> URL {
        VMImage.cache.appendingPathComponent(String(digest.dropFirst(7)), isDirectory: true)
            .appendingPathComponent(".\(part.digest.dropFirst(7)).part")
    }

    private func fileSize(_ file: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    }

    private func waitUntil(_ file: URL, holds bytes: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while fileSize(file) < bytes {
            try #require(ContinuousClock.now < deadline, "\(file.lastPathComponent) never got \(bytes) bytes")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aNewerImageUnderTheSameTagReplacesTheOlderOneWhileOtherTagsStay() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)
        let base = try registry.reference("hangar-macos:base")
        let options = CreateOptions(diskSize: 1 << 20)
        _ = try await registry.push(bundle, tag: "base")
        _ = try await VMImage.createVM(name: "one", image: base, os: .linux, options: options) { _ in }
        let handle = try FileHandle(forWritingTo: bundle.diskURL)
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()

        let second = try await registry.push(bundle, tag: "base")
        _ = try await VMImage.createVM(name: "two", image: base, os: .linux, options: options) { _ in }

        #expect(VMImage.cachedImages().map(\.record.reference) == [base.adding(digest: second).description])
        #expect(VMImage.cachedImages().first?.record.title == "Linux image from \(registry.host)/hangar-macos:base")
        #expect(try VMLibrary.bundle(named: "one").loadConfig().os == .linux)

        let vanilla = try registry.reference("hangar-macos:vanilla")
        let handleAgain = try FileHandle(forWritingTo: bundle.diskURL)
        try handleAgain.write(contentsOf: Data("vanilla".utf8))
        try handleAgain.close()
        _ = try await registry.push(bundle, tag: "vanilla")
        _ = try await VMImage.createVM(name: "three", image: vanilla, os: .linux, options: options) { _ in }
        #expect(VMImage.cachedImages().count == 2)
    }

    @Test func taggedImagesAreUsedByTheirDigestAndOnlyForTheirOwnOS() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        let tagged = try registry.reference("hangar-macos:base-27.0.1")

        let pinned = try await VMImage.pinned(tagged, credentials: nil)

        #expect(pinned.description == "\(registry.host)/hangar-macos:base-27.0.1@\(digest)")

        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "copy", image: tagged, os: .windows, options: CreateOptions(diskSize: 1 << 20)
                ) { _ in }
            } == "This is a Linux image, not Windows.")
        #expect(VMLibrary.all().map(\.name) == ["builder"])
        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "copy", image: tagged, os: .linux, options: CreateOptions(diskSize: 1 << 20),
                    macAccount: MacProvisioning(fullName: "Dev", username: "dev", password: "secret")
                ) { _ in }
            } == "A macOS account goes with a macOS image.")

        let copy = try await VMImage.createVM(
            name: "copy", image: tagged, os: .linux, options: CreateOptions(diskSize: 1 << 20)
        ) { _ in }
        #expect(try copy.loadConfig().os == .linux)
        #expect(VMImage.cachedImages().map(\.record.reference) == [pinned.description])
    }

    @Test func wrongAccountsAreRefusedBeforeTheDiskIsDownloaded() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make(.linux)
        try bundle.updateConfig { $0.sshUser = "dev" }
        let digest = try await registry.push(bundle)
        let pinned = try registry.reference("hangar-macos@\(digest)")

        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "copy", image: pinned, os: .linux, options: CreateOptions(diskSize: 1 << 20),
                    macAccount: MacProvisioning(fullName: "Dev", username: "dev", password: "secret")
                ) { _ in }
            } == "A macOS account goes with a macOS image.")

        #expect(
            !FileManager.default.fileExists(
                atPath: VMImage.cache.appendingPathComponent(String(digest.dropFirst(7))).appendingPathComponent(
                    "disk.img"
                ).path))

        let old = VMImage.Config(
            os: .macOS, diskSize: 1 << 20,
            macOS: VMImage.MacDetails(
                version: "26.4", build: "25E1", hardwareModel: try TestVM.hardwareModel, minimumCPUCount: 2,
                minimumMemorySize: 4 << 30))
        #expect(
            failureMessage {
                try VMImage.check(
                    old, options: CreateOptions(diskSize: 1 << 20),
                    macAccount: MacProvisioning(fullName: "Dev", username: "dev", password: "secret"),
                    linuxAccount: nil, userData: nil)
            } == "Automatic account setup needs a macOS 27 or newer guest.")
    }

    @Test func lookingUpAnImageReadsOnlyItsSettings() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        let tagged = try registry.reference("hangar-macos:base-27.0.1")

        let (pinned, config) = try await VMImage.inspect(tagged, credentials: nil)

        #expect(pinned.digest == digest && config.os == .linux)
        #expect(VMImage.cacheFolders().isEmpty)
    }

    @Test func aWrongOSStopsBeforeTheDiskIsDownloaded() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        let pinned = try registry.reference("hangar-macos@\(digest)")

        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "copy", image: pinned, os: .windows, options: CreateOptions(diskSize: 1 << 20)
                ) { _ in }
            } == "This is a Linux image, not Windows.")

        let folder = VMImage.cache.appendingPathComponent(String(digest.dropFirst(7)))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("disk.img").path))
    }

    @Test func aTamperedPartIsRefused() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make()
        let digest = try await registry.push(bundle)
        let part = try #require(try registry.manifest(digest).layers.first { $0.mediaType == VMImage.diskType })
        registry.corrupt(part.digest)

        #expect(
            await failureMessage { try await registry.pull(digest) }
                == "A disk part didn't match its digest (\(part.digest)).")

        let folder = VMImage.cache.appendingPathComponent(String(digest.dropFirst(7)))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("image.json").path))
        #expect(!FileManager.default.fileExists(atPath: partialFile(of: part, inImage: digest).path))
        #expect(registry.ranges.isEmpty)
    }

    @Test func aMissingPartFailsAtOnceInsteadOfBeingTriedAgain() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make())
        let part = try #require(try registry.manifest(digest).layers.first { $0.mediaType == VMImage.diskType })
        registry.forget("blobs/\(part.digest)")
        let started = ContinuousClock.now

        let missing = await #expect(throws: HangarError.self) { try await registry.pull(digest) }

        #expect(missing?.message == "Download failed: HTTP 404 from 127.0.0.1.")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aPullWaitingForAnImageThatGetsDeletedStops() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        let folder = VMImage.cache.appendingPathComponent(String(Digests.hex(of: digest)), isDirectory: true)
        try HangarPaths.createDirectory(folder)
        let deleting = FileLock(url: folder.appendingPathComponent("pull.lock"))
        #expect(try deleting.tryLock(.exclusive))

        async let waiting = failureMessage { _ = try await registry.pull(digest) }
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.removeItem(at: folder)
        deleting.unlock()

        #expect(await waiting == VMImage.removedWhileInUse.message)
    }

    @Test func creatingAVMMarksItsImageAsUsed() async throws {
        let registry = try await StubRegistry()
        let image = try registry.reference("hangar-macos:base")
        let options = CreateOptions(diskSize: 1 << 20)
        _ = try await registry.push(try TestVM.make(.linux), tag: "base")
        _ = try await VMImage.createVM(name: "one", image: image, os: .linux, options: options) { _ in }
        let folder = try #require(VMImage.cachedImages().first?.folder)
        let longAgo = Date().addingTimeInterval(-40 * 86_400)
        for item in [folder, folder.appendingPathComponent("image.json")] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: item.path)
        }

        _ = try await VMImage.createVM(name: "two", image: image, os: .linux, options: options) { _ in }

        let entry = try #require(await CacheStore.entries().first { $0.kind == .image })
        #expect(entry.lastUsed > longAgo.addingTimeInterval(86_400))
    }

    @Test func downloadsCarryOnWhereTheyStopped() async throws {
        for answer in [StubRegistry.RangeAnswer.honour, .ignore, .wrongStart] {
            try? FileManager.default.removeItem(at: VMImage.cache)
            let registry = try await StubRegistry()
            let bundle = try TestVM.make(named: "builder-\(answer)")
            let disk = try Data(contentsOf: bundle.diskURL)
            let digest = try await registry.push(bundle)
            let part = try #require(try registry.manifest(digest).layers.first { $0.mediaType == VMImage.diskType })
            registry.answerRanges(answer)
            registry.holdNextDownload(after: 1000)

            async let pulled = registry.pull(digest)
            try await waitUntil(partialFile(of: part, inImage: digest), holds: 1000)
            registry.dropHeldDownload()
            let cached = try await pulled

            #expect(try Data(contentsOf: cached.disk) == disk)
            #expect(registry.ranges == ["bytes=1000-"])
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: cached.folder.path).filter {
                $0.hasSuffix(".part")
            }
            #expect(leftovers.isEmpty)
        }
    }

    @Test func aDamagedPartialIsDownloadedAgainOnce() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make()
        let disk = try Data(contentsOf: bundle.diskURL)
        let digest = try await registry.push(bundle)
        let part = try #require(try registry.manifest(digest).layers.first { $0.mediaType == VMImage.diskType })
        let partial = partialFile(of: part, inImage: digest)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: partial)

        let cached = try await registry.pull(digest)

        #expect(try Data(contentsOf: cached.disk) == disk)
        #expect(registry.ranges == ["bytes=100-"])
    }

    @Test func aWrongUnpackedDigestIsRefused() async throws {
        let registry = try await StubRegistry()
        let bundle = try TestVM.make()
        let digest = try await registry.push(bundle)
        var manifest = try registry.manifest(digest)
        let index = try #require(manifest.layers.firstIndex { $0.mediaType == VMImage.diskType })
        manifest.layers[index].annotations?[VMImage.plainDigestKey] = VMImage.digest(of: Data("other".utf8))
        let forged = try JSONEncoder().encode(manifest)
        registry.put(forged, at: "manifests/\(VMImage.digest(of: forged))")

        #expect(
            await failureMessage { try await registry.pull(VMImage.digest(of: forged)) }
                == "A disk part unpacked to the wrong contents (\(manifest.layers[index].digest)).")
    }
}
