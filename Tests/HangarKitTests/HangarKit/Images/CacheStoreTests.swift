import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct CacheStoreTests {
    @Test func cachedDownloadsAreListedAndDeleted() async throws {
        let cache = HangarPaths.cache
        for folder in ["ipsw", "macos/26B123", "iso"] {
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(count: 4096).write(to: cache.appendingPathComponent("ipsw/latest-26B123.ipsw"))
        try Data(count: 10).write(to: cache.appendingPathComponent("iso/debian-0123456789abcdef.raw"))
        try Data(count: 10).write(to: cache.appendingPathComponent("iso/virtio-win-0.1.302.iso"))
        try Data(count: 10).write(to: cache.appendingPathComponent("iso/0123456789ab-alpine.iso"))
        try Data().write(to: cache.appendingPathComponent("iso/windows-media.lock"))
        try Data(count: 10).write(to: cache.appendingPathComponent("iso/debian-0123456789abcdef.raw.partial"))
        try Data(count: 10).write(to: cache.appendingPathComponent("iso/0123456789ab-other.iso.download"))

        let entries = await CacheStore.entries()

        #expect(entries.count == 5)
        #expect(entries.contains { $0.kind == .macOS && $0.title == "Restore image 26B123" })
        #expect(entries.contains { $0.kind == .linux && $0.title == "Debian 13 cloud image" })
        #expect(entries.contains { $0.kind == .windows })
        #expect(entries.contains { $0.kind == .other && $0.title == "alpine.iso" })

        let image = try #require(entries.first { $0.kind == .macOS })
        let lock = FileLock(url: image.url.appendingPathExtension("lock"))
        #expect(try lock.tryLock(.exclusive))
        #expect(
            await failureMessage { try await CacheStore.delete(image) }
                == "Restore image 26B123 is in use right now; try again when the download or VM creation has finished.")
        lock.unlock()
        try await CacheStore.delete(image)
        #expect(!FileManager.default.fileExists(atPath: image.url.path))

        let outside = CacheEntry(url: HangarPaths.home, kind: .other, title: "home", size: 0, lastUsed: Date())
        #expect(await failureMessage { try await CacheStore.delete(outside) } == "home is no longer in Hangar's cache.")

        let iso = try #require(entries.first { $0.title == "alpine.iso" })
        let vm = VMBundle(url: HangarPaths.vms.appendingPathComponent("installer", isDirectory: true))
        try FileManager.default.createDirectory(at: vm.url, withIntermediateDirectories: true)
        var config = VMConfig(
            os: .linux, cpuCount: 1, memorySize: 1 << 30, display: .linuxDefault,
            network: NetworkSettings(mode: .none, macAddress: VMConfig.randomMACAddress()))
        config.isoPath = iso.url.path
        try vm.saveConfig(config)
        #expect(
            await failureMessage { try await CacheStore.delete(iso) }
                == "alpine.iso is attached to 'installer'. Detach it in Virtual Machine › ISO first.")
        config.isoPath = nil
        try vm.saveConfig(config)
        try await CacheStore.delete(iso)
        #expect(!FileManager.default.fileExists(atPath: iso.url.path))
    }

    @Test func pruningPicksTheLeastRecentlyUsed() async throws {
        let iso = HangarPaths.cache.appendingPathComponent("iso", isDirectory: true)
        try FileManager.default.createDirectory(at: iso, withIntermediateDirectories: true)
        let now = Date()
        for (name, daysAgo) in [("old", 40), ("middle", 20), ("new", 1)] {
            let file = iso.appendingPathComponent("0123456789ab-\(name).iso")
            try Data(repeating: 1, count: 1 << 20).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-Double(daysAgo) * 86_400)],
                ofItemAtPath: file.path)
        }
        func pruned(_ days: Int?, _ budget: UInt64?) async throws -> [String] {
            try await CacheStore.pruneList(olderThanDays: days, spaceBudget: budget, now: now).map(\.title)
        }

        #expect(try await pruned(30, nil) == ["old.iso"])
        #expect(try await pruned(10, nil) == ["old.iso", "middle.iso"])
        #expect(try await pruned(nil, 3 << 20) == [])
        #expect(try await pruned(nil, (3 << 20) - 1) == ["old.iso"])
        #expect(try await pruned(30, 1 << 20) == ["old.iso", "middle.iso"])
        #expect(try await pruned(nil, 0) == ["old.iso", "middle.iso", "new.iso"])
        #expect(await failureMessage { try await pruned(nil, nil) } == "Give a number of days, a space budget or both.")
        #expect(await failureMessage { try await pruned(-1, nil) } == "Give a number of days from 0 up.")

        _ = try await Downloader.cached(
            try #require(URL(string: "https://example.invalid/x")),
            as: iso.appendingPathComponent("0123456789ab-old.iso"),
            phase: "", progress: { _ in })
        #expect(try await pruned(30, nil) == [])
    }
}
