import Compression
import CryptoKit
import Darwin
import Foundation
import HangarSupport
import System

extension VMImage {
    package static let wholeDiskWarning =
        "The whole disk goes into the image: accounts and their password hashes, SSH host keys, files, logs, "
        + "and swap or hibernation files. Remove what others shouldn't have before you push. On Linux, also empty /etc/machine-id "
        + "(sudo truncate -s0 /etc/machine-id) so each VM made from the image gets its own."
    package static let runningSnapshotWarning =
        "A snapshot taken while the VM ran holds its disk as if the power was cut; shut the VM down "
        + "before taking a snapshot you share."

    private struct OCIConfig: Encodable {
        struct RootFS: Encodable {
            var type = "layers"
            var diffIDs: [String] = []

            enum CodingKeys: String, CodingKey {
                case type
                case diffIDs = "diff_ids"
            }
        }

        var architecture = "arm64"
        var os: String
        var rootfs = RootFS()

        init(os: GuestOS) {
            self.os = os == .macOS ? "darwin" : os.rawValue
        }
    }

    private struct Source {
        let name: String
        let disk: URL
        let nvram: URL
        let config: VMConfig
    }

    package static func isImageFile(_ target: String) -> Bool {
        target.hasSuffix(".tar")
    }

    package static func uploadChunkSize(megabytes: Int) throws -> Int {
        guard megabytes == 0 || (5...512).contains(megabytes) else {
            throw HangarError("Give a chunk size from 5 to 512 MB, or 0 to send each part in one request.")
        }
        return megabytes << 20
    }

    @concurrent
    package static func push(
        _ bundle: VMBundle, snapshot: VMSnapshot? = nil, to references: [ImageReference],
        macOS: MacDetails? = nil, credentials: RegistryCredentials?, uploadChunkSize: Int = 0,
        report: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let first = references.first,
            references.allSatisfy({
                $0.registry == first.registry && $0.repository == first.repository && $0.tag != nil && $0.digest == nil
            })
        else {
            throw HangarError("Give one or more tags in one repository, like ghcr.io/acme/ci-linux:1.0.")
        }

        let client = RegistryClient(
            image: first, credentials: credentials, pushes: true, uploadChunkSize: uploadChunkSize)
        let manifest = try await withSource(of: bundle, snapshot: snapshot) { source in
            try await pack(source, macOS: macOS, into: client, report: report)
        }
        for reference in references {
            try await client.putManifest(manifest, as: reference.tag ?? "")
        }
        return digest(of: manifest)
    }

    /// `replacing` is for the app, whose save panel has asked the user before replacing a file; `hangar export`
    /// refuses a file that is there.
    @concurrent
    package static func export(
        _ bundle: VMBundle, snapshot: VMSnapshot? = nil, to file: URL, replacing canReplace: Bool = false,
        report: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let writer = try ImageArchiveWriter(creating: file, replacing: canReplace)
        do {
            let manifest = try await withSource(of: bundle, snapshot: snapshot) { source in
                try await pack(source, macOS: nil, into: writer, report: report)
            }
            return try await writer.finish(manifest: manifest)
        } catch {
            await writer.discard()
            throw error
        }
    }

    private static func withSource(of bundle: VMBundle, snapshot: VMSnapshot?, _ body: (Source) async throws -> Data)
        async throws -> Data
    {
        if let snapshot {
            let copy = bundle.snapshotsURL.appendingPathComponent(
                Snapshots.exportingPrefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: copy) }
            let inUse = FileLock(url: Snapshots.exportLock(in: copy))
            try inUse.lock(.exclusive)
            defer { inUse.unlock() }
            return try await body(try copySnapshot(snapshot, of: bundle, to: copy))
        }

        let lock = try VMLibrary.lockStopped(bundle)
        defer { lock.unlock() }
        return try await body(
            Source(
                name: "'\(bundle.name)'", disk: bundle.diskURL, nvram: bundle.nvramURL, config: try bundle.loadConfig())
        )
    }

    private static func copySnapshot(_ snapshot: VMSnapshot, of bundle: VMBundle, to folder: URL) throws -> Source {
        let disk = folder.appendingPathComponent("disk.img")
        let nvram = folder.appendingPathComponent("nvram.bin")
        let config: VMConfig
        do {
            try VMLibrary.cloneFile(from: snapshot.diskURL, to: disk)
            try VMLibrary.cloneFile(from: snapshot.nvramURL, to: nvram)
            config = try VMConfig.read(from: snapshot.configURL)
        } catch {
            throw HangarError("Could not read the snapshot '\(snapshot.name)': \(error.localizedDescription)")
        }
        return Source(name: "\(bundle.name)'s snapshot '\(snapshot.name)'", disk: disk, nvram: nvram, config: config)
    }

    private static func pack(
        _ source: Source, macOS: MacDetails?, into sink: any ImageSink,
        report: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        let config = try imageConfig(of: source, macOS: macOS)
        let chunks = try await packDisk(source.disk, size: config.diskSize, into: sink, report: report)
        let nvram = try Data(contentsOf: source.nvram)
        guard (1...maximumNVRAM).contains(nvram.count) else {
            throw HangarError("\(source.name)'s NVRAM can't go into an image.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let nvramLayer = try await upload(nvram, as: nvramType, to: sink)
        let configLayer = try await upload(try encoder.encode(config), as: configType, to: sink)
        let stub = try await upload(try encoder.encode(OCIConfig(os: config.os)), as: imageConfigType, to: sink)
        let manifest = Manifest(
            config: stub,
            layers: [configLayer, nvramLayer] + chunks.map(diskLayer(for:)),
            annotations: [
                "org.opencontainers.image.title": config.title,
                "org.opencontainers.image.created": Date().formatted(.iso8601),
            ])

        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= maximumManifest else {
            throw HangarError("\(source.name)'s disk has too many parts with data to fit in one image.")
        }
        return manifestData
    }

    private static func packDisk(
        _ disk: URL, size diskSize: UInt64, into sink: any ImageSink, report: @escaping @Sendable (String) -> Void
    ) async throws -> [Chunk] {
        let count = Int((diskSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        var chunks: [Chunk] = []
        var done = 0
        try await withThrowingTaskGroup(of: Chunk?.self) { group in
            var next = 0
            func add() -> Bool {
                guard next < count else { return false }
                let index = next
                next += 1
                group.addTask { try await pack(index, of: disk, size: diskSize, into: sink) }
                return true
            }
            for _ in 0..<parallelTransfers {
                guard add() else { break }
            }
            while let chunk = try await group.next() {
                if let chunk { chunks.append(chunk) }
                done += 1
                let sent = ByteSize.format(UInt64(chunks.reduce(0) { $0 + $1.size }))
                report("Disk: \(done) of \(count) parts, \(chunks.count) with data, \(sent) sent")
                _ = add()
            }
        }
        return chunks.sorted { $0.offset < $1.offset }
    }

    private static func upload(_ data: Data, as mediaType: String, to sink: any ImageSink) async throws -> Descriptor {
        let dataDigest = digest(of: data)
        try await sink.upload(data, digest: dataDigest)
        return Descriptor(mediaType: mediaType, digest: dataDigest, size: Int64(data.count))
    }

    private static func diskLayer(for chunk: Chunk) -> Descriptor {
        Descriptor(
            mediaType: diskType, digest: chunk.digest, size: chunk.size,
            annotations: [
                offsetKey: String(chunk.offset), lengthKey: String(chunk.length), plainDigestKey: chunk.plainDigest,
            ])
    }

    private static func imageConfig(of source: Source, macOS: MacDetails?) throws -> Config {
        let vm = source.config
        // Hangar's own image tools (`hangar image build --push`) pass macOS details. Their vanilla image is
        // never started on purpose, so each VM made from it sets up its own account on its first start.
        let isHangarMacOSImage = macOS != nil
        guard vm.provisioning == nil, vm.firstStartedAt != nil || isHangarMacOSImage else {
            throw HangarError(
                "\(source.name) hasn't started yet, so its accounts aren't set up on the disk; start it once, then push it."
            )
        }

        if vm.os != .macOS, macOS != nil {
            throw HangarError("macOS details go with a macOS VM.")
        }

        if let account = vm.sshUser, !VMConfig.isValidUserName(account) {
            throw HangarError("\(source.name)'s account '\(account)' can't go into an image.")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: source.disk.path)
        guard let diskSize = (attributes[.size] as? NSNumber)?.uint64Value, diskSize > 0, diskSize <= maximumDiskSize
        else {
            throw HangarError("\(source.name)'s disk can't go into an image.")
        }

        let details = vm.os == .macOS ? try macOS ?? MacImage.exportedDetails(of: vm) : nil
        return Config(
            os: vm.os, diskSize: diskSize, account: vm.sshUser, macOS: details,
            remoteDesktop: vm.os == .windows ? vm.remoteDesktop : nil)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).ociDigest
    }

    private static func pack(_ index: Int, of disk: URL, size: UInt64, into sink: any ImageSink) async throws -> Chunk?
    {
        let offset = UInt64(index) * UInt64(chunkSize)
        let length = Int(min(UInt64(chunkSize), size - offset))
        guard let packed = try compress(disk, at: offset, length: length) else { return nil }
        let compressed = packed.data
        let chunk = Chunk(
            offset: offset, length: length, plainDigest: packed.plainDigest, digest: digest(of: compressed),
            size: Int64(compressed.count))
        var attempt = 0
        while true {
            do {
                try await sink.upload(compressed, digest: chunk.digest)
                return chunk
            } catch let error where TemporaryFailure.isTemporary(error) {
                attempt += 1
                guard attempt < transferAttempts, !Task.isCancelled else { throw error }
                try await Task.sleep(for: TemporaryFailure.retryDelay(attempt: attempt))
            }
        }
    }

    /// Reads and compresses the part in pieces, so only its compressed form is held; a part with no data gives nil.
    static func compress(_ disk: URL, at offset: UInt64, length: Int) throws -> (data: Data, plainDigest: String)? {
        guard try DiskRegion.hasData(disk, at: offset, length: UInt64(length)) else { return nil }
        var compressed = Data()
        compressed.reserveCapacity(length)
        var hash = SHA256()
        var isEmpty = true
        let filter = try OutputFilter(.compress, using: .lzfse) { compressed.append($0 ?? Data()) }
        try DiskRegion.read(disk, at: offset, length: UInt64(length)) { piece in
            hash.update(data: piece)
            isEmpty = isEmpty && DiskRegion.isZero(piece)
            try filter.write(piece)
        }
        try filter.finalize()
        guard !isEmpty else { return nil }
        return (compressed, hash.finalize().ociDigest)
    }
}
