import Foundation
import HangarSupport

package enum CacheStore {
    static let secondsPerDay: TimeInterval = 86_400

    @concurrent
    package static func entries() async -> [CacheEntry] {
        let entries = restoreImageEntries() + installedMacOSEntries() + imageEntries() + downloadEntries()
        return entries.sorted { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) }
    }

    private static func restoreImageEntries() -> [CacheEntry] {
        items(in: "ipsw").map { url in
            let build = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "latest-", with: "")
            return CacheEntry(
                url: url, kind: .macOS, title: "Restore image \(build)", size: allocatedSize(url),
                lastUsed: lastUsed(url))
        }
    }

    private static func installedMacOSEntries() -> [CacheEntry] {
        items(in: "macos").map { url in
            let info = try? JSON.read(MacTemplates.Info.self, from: url.appendingPathComponent("template.json"))
            let title = info.map { "macOS \($0.version) (\($0.buildVersion)), ready to copy" } ?? url.lastPathComponent
            return CacheEntry(
                url: url, kind: .installedMacOS, title: title, size: allocatedSize(url),
                lastUsed: lastUsed(url.appendingPathComponent("template.json")))
        }
    }

    private static func imageEntries() -> [CacheEntry] {
        VMImage.cacheFolders().map { folder in
            let title = VMImage.record(in: folder)?.title ?? "Unfinished or unreadable image"
            return CacheEntry(
                url: folder, kind: .image, title: title, size: allocatedSize(folder),
                lastUsed: max(lastUsed(folder), lastUsed(folder.appendingPathComponent("image.json"))))
        }
    }

    private static func downloadEntries() -> [CacheEntry] {
        items(in: "iso").map { url in
            let (kind, title) = describeDownload(named: url.lastPathComponent)
            return CacheEntry(url: url, kind: kind, title: title, size: allocatedSize(url), lastUsed: lastUsed(url))
        }
    }

    private static func describeDownload(named name: String) -> (CacheEntry.Kind, String) {
        if let template = LinuxCloudImage.allCases.first(where: { name.hasPrefix("\($0.rawValue)-") }) {
            return (.linux, "\(template.title) cloud image")
        }
        if name.hasPrefix("virtio-win") {
            return (.windows, "Windows drivers (\(name))")
        }
        if name.hasPrefix("winfsp") {
            return (.windows, name)
        }

        let keyLength = Downloader.cacheKeyLength
        let hasCacheKey = name.count > keyLength + 1 && name.dropFirst(keyLength).first == "-"
        return (.other, hasCacheKey ? String(name.dropFirst(keyLength + 1)) : name)
    }

    private static func items(in folder: String) -> [URL] {
        let directory = HangarPaths.cache.appendingPathComponent(folder, isDirectory: true)
        let contents =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter {
            !$0.lastPathComponent.hasPrefix(".")
                && !["lock", "download", "partial", "resume"].contains($0.pathExtension)
        }
    }

    @concurrent
    package static func delete(_ entry: CacheEntry) async throws {
        guard await entries().contains(where: { $0.url == entry.url }) else {
            throw HangarError("\(entry.title) is no longer in Hangar's cache.")
        }

        let lock = FileLock(
            url: entry.kind == .image
                ? entry.url.appendingPathComponent("pull.lock") : entry.url.appendingPathExtension("lock"))
        guard try lock.tryLock(.exclusive) else {
            throw HangarError(
                "\(entry.title) is in use right now; try again when the download or VM creation has finished.")
        }
        defer { lock.unlock() }

        let path = entry.url.standardizedFileURL.path

        if let user = VMLibrary.all().first(where: {
            (try? $0.loadConfig())?.isoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
        }) {
            throw HangarError("\(entry.title) is attached to '\(user.name)'. Detach it in Virtual Machine › ISO first.")
        }

        try FileManager.default.removeItem(at: entry.url)
        try? FileManager.default.removeItem(at: lock.url)
    }

    package static func pruneList(olderThanDays days: Int?, spaceBudget: UInt64?, now: Date = Date()) async throws
        -> [CacheEntry]
    {
        guard days != nil || spaceBudget != nil else {
            throw HangarError("Give a number of days, a space budget or both.")
        }
        guard (days ?? 0) >= 0 else { throw HangarError("Give a number of days from 0 up.") }
        var kept = await entries().sorted { $0.lastUsed > $1.lastUsed }
        var chosen: [CacheEntry] = []
        if let days {
            let cutoff = now.addingTimeInterval(-Double(days) * secondsPerDay)
            chosen = kept.filter { $0.lastUsed < cutoff }.reversed()
            kept.removeAll { $0.lastUsed < cutoff }
        }
        if let spaceBudget {
            var total = kept.reduce(0) { $0 + $1.size }
            while total > spaceBudget, let oldest = kept.popLast() {
                chosen.append(oldest)
                total -= oldest.size
            }
        }
        return chosen
    }

    static func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func lastUsed(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func allocatedSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return UInt64(values.totalFileAllocatedSize ?? 0) }
        var total: UInt64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walker?.nextObject() as? URL {
            total += UInt64(
                (try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
