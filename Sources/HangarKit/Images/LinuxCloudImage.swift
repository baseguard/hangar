import Foundation
import HangarDisks
import HangarSupport

package enum LinuxCloudImage: String, Codable, CaseIterable, Identifiable, Sendable {
    case debian
    case ubuntu
    case fedora

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .debian: "Debian 13"
        case .ubuntu: "Ubuntu 26.04 LTS"
        case .fedora: "Fedora 45"
        }
    }

    package var source: String { cloudImage.archive.host ?? "" }

    /// Where the image's digest comes from: the list its publisher keeps next to an image that follows the latest
    /// release, or the digest Hangar knows for an image named by its release, so no mirror's list is trusted.
    enum Checksum {
        case listedIn(URL)
        case known(String)
    }

    var cloudImage: (archive: URL, checksum: Checksum) {
        switch self {
        case .debian:
            (
                URL(
                    constant: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2"),
                .listedIn(URL(constant: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"))
            )
        case .ubuntu:
            (
                URL(
                    constant:
                        "https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64.img"
                ),
                .listedIn(URL(constant: "https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS"))
            )
        // Fedora names its images by release and compose, and sends each download to another mirror.
        case .fedora:
            (
                URL(
                    constant:
                        "https://download.fedoraproject.org/pub/fedora/linux/releases/45/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-45-1.4.aarch64.qcow2"
                ),
                .known("1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c")
            )
        }
    }

    @concurrent
    package func disk(progress: @escaping ProgressHandler) async throws -> URL {
        let (archive, checksum) = cloudImage
        let digest = try await digest(of: archive, from: checksum, progress: progress)
        let stem = "\(rawValue)-\(digest.prefix(16))"
        let disk = HangarPaths.isoCache.appendingPathComponent("\(stem).raw")
        if FileManager.default.fileExists(atPath: disk.path) { return markedUsed(disk) }
        let download = try await Downloader.cached(
            archive, as: HangarPaths.isoCache.appendingPathComponent("\(stem)-\(archive.lastPathComponent)"),
            digest: digest, phase: "Downloading \(title)", progress: progress)
        let lockURL = disk.appendingPathExtension("lock")
        let lock = FileLock(url: lockURL)

        try await lock.lockWaiting("Waiting for another VM to unpack \(title)", progress: progress)
        defer {
            if FileManager.default.fileExists(atPath: disk.path) { try? FileManager.default.removeItem(at: lockURL) }
            lock.unlock()
        }
        if FileManager.default.fileExists(atPath: disk.path) { return markedUsed(disk) }
        let partial = disk.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        do {
            try QCOW2.convert(download, to: partial, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        try FileManager.default.moveItem(at: partial, to: disk)
        try? FileManager.default.removeItem(at: download)
        removeOlderImages(keeping: stem)

        return disk
    }

    private func digest(of archive: URL, from checksum: Checksum, progress: ProgressHandler) async throws -> String {
        switch checksum {
        case .listedIn(let list):
            progress(CreationProgress(phase: "Looking up the checksum of \(title)"))
            return try await Downloader.checksum(of: archive.lastPathComponent, listedIn: list)
        case .known(let digest):
            return digest
        }
    }

    // VMs clone the disk, which leaves its date alone, so without this prune would take a disk in daily use.
    private func markedUsed(_ disk: URL) -> URL {
        CacheStore.markUsed(disk)
        return disk
    }

    private func removeOlderImages(keeping stem: String) {
        let cache = HangarPaths.isoCache
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        for file in files where file.hasPrefix("\(rawValue)-") && !file.hasPrefix(stem) && !file.hasSuffix(".lock") {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(file))
        }
    }
}
