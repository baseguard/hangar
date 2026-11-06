import Compression
import CryptoKit
import Foundation
import HangarDisks
import HangarSupport

extension VMImage {
    static func pull(
        _ reference: ImageReference, named name: String, credentials: RegistryCredentials? = nil,
        accept: (Config) throws -> Void = { _ in }, progress: @escaping ProgressHandler
    ) async throws -> Cached {
        guard let digest = reference.digest else { throw HangarError("Hangar only downloads images pinned by digest.") }
        return try await pull(
            digest, from: RegistryClient(image: reference, credentials: credentials), named: name,
            reference: reference.description, accept: accept, progress: progress)
    }

    static func pull(
        _ digest: String, from source: any BlobSource, named name: String, reference: String,
        accept: (Config) throws -> Void, progress: @escaping ProgressHandler
    ) async throws -> Cached {
        try HangarPaths.createDirectory(cache)
        let folder = cache.appendingPathComponent(String(Digests.hex(of: digest)), isDirectory: true)
        try HangarPaths.createDirectory(folder)
        let lock = try await pullLock(in: folder, progress: progress)
        defer { lock.unlock() }

        let recordURL = folder.appendingPathComponent("image.json")
        if let record = try? JSON.read(Record.self, from: recordURL) {
            try accept(record.config)
            return Cached(folder: folder, config: record.config)
        }

        progress(CreationProgress(phase: "Looking up the image"))
        let (layout, config) = try await settings(of: try await source.manifest(digest: digest), from: source)
        try accept(config)
        let cached = Cached(folder: folder, config: config)

        let finished = FinishedChunks(url: folder.appendingPathComponent("finished.json"))
        if !FileManager.default.fileExists(atPath: cached.disk.path) {
            finished.reset()
            try SparseFile.create(at: cached.disk, size: config.diskSize)
        }

        let pending = layout.chunks.filter { !finished.contains($0.digest) }
        try checkFreeSpace(in: folder, for: pending, nvram: layout.nvram, title: config.title)
        try await saveNVRAM(layout.nvram.digest, from: source, to: cached.nvram)
        try await downloadParts(
            pending, of: layout, title: config.title, into: cached.disk, folder: folder, from: source,
            finished: finished, progress: progress)

        let parts = layout.chunks.map { Part(offset: $0.offset, length: $0.length, plainDigest: $0.plainDigest) }
        let record = Record(name: name, reference: reference, config: config, parts: parts, pulledAt: Date())
        try JSON.write(record, to: recordURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        try? FileManager.default.removeItem(at: finished.url)
        removeOlderImages(named: name, keeping: folder)
        return cached
    }

    private static func pullLock(in folder: URL, progress: ProgressHandler) async throws -> FileLock {
        let lock = FileLock(url: folder.appendingPathComponent("pull.lock"))
        try await lock.lockWaiting("Waiting for another download of this image", progress: progress)
        guard lock.isStillAtItsPath else {
            lock.unlock()
            throw removedWhileInUse
        }
        return lock
    }

    /// A pull leaves at least this much free, so the Mac and the VM still have room to work.
    private static let spaceToKeep: UInt64 = 2 << 30

    private static func checkFreeSpace(in folder: URL, for pending: [Chunk], nvram: Descriptor, title: String) throws {
        let needed = pending.reduce(UInt64(nvram.size)) { $0 + UInt64($1.length) }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free >= 0,
            UInt64(free) < needed + spaceToKeep
        else { return }
        throw HangarError(
            "The \(title) needs \(ByteSize.format(needed)) of free space; this Mac has \(ByteSize.format(UInt64(free))). "
                + "Delete downloads you no longer need in Settings › Downloads or with `hangar prune`.")
    }

    private static func saveNVRAM(_ digest: String, from source: any BlobSource, to url: URL) async throws {
        let nvram = try await source.blob(digest, limit: maximumNVRAM)
        guard FileManager.default.createFile(atPath: url.path, contents: nvram, attributes: [.posixPermissions: 0o600])
        else {
            throw HangarError("Could not save the image's NVRAM.")
        }
    }

    private static func downloadParts(
        _ pending: [Chunk], of layout: Layout, title: String, into disk: URL, folder: URL, from source: any BlobSource,
        finished: FinishedChunks, progress: @escaping ProgressHandler
    ) async throws {
        let local = localParts(excluding: folder)
        let reused = pending.count { local[$0.plainDigest] != nil }
        let counter = TransferCounter(
            total: layout.downloadSize,
            done: layout.chunks.filter { finished.contains($0.digest) }.reduce(0) { $0 + $1.size },
            phase: "Downloading the \(title)"
                + (reused > 0 ? " (\(reused) of \(pending.count) parts are already on this Mac)" : ""),
            progress: progress)

        let sameParts = Dictionary(grouping: pending, by: \.digest).values.sorted { $0[0].offset < $1[0].offset }
        var queue = sameParts.makeIterator()
        try await withThrowingTaskGroup(of: String.self) { group in
            func next() -> Bool {
                guard let copies = queue.next() else { return false }
                let reusable = local[copies[0].plainDigest]
                group.addTask {
                    try await fetch(copies, into: disk, folder: folder, from: source, local: reusable, counter: counter)
                }
                return true
            }
            for _ in 0..<parallelTransfers {
                guard next() else { break }
            }
            while let digest = try await group.next() {
                try finished.add(digest)
                _ = next()
            }
        }
    }

    private static func fetch(
        _ copies: [Chunk], into disk: URL, folder: URL, from source: any BlobSource, local: LocalPart?,
        counter: TransferCounter
    ) async throws -> String {
        let chunk = copies[0]
        try await writePart(chunk, into: disk, folder: folder, from: source, local: local, counter: counter)
        for copy in copies.dropFirst() {
            try DiskRegion.copy(in: disk, from: chunk.offset, to: copy.offset, length: UInt64(chunk.length))
            counter.add(copy.size)
        }
        return chunk.digest
    }

    private static func writePart(
        _ chunk: Chunk, into disk: URL, folder: URL, from source: any BlobSource, local: LocalPart?,
        counter: TransferCounter
    ) async throws {
        if let local, (try? copyLocalPart(local, of: chunk, into: disk)) == true {
            counter.add(chunk.size)
            return
        }

        let part = folder.appendingPathComponent(".\(Digests.hex(of: chunk.digest)).part")
        let receiver = try PartReceiver.open(part, limit: chunk.size, counter: counter)
        try await download(chunk, from: source, into: receiver)
        defer { try? receiver.discard() }
        try unpack(part, of: chunk, into: disk)
    }

    /// The same disk part in another image on this Mac, checked while it is copied: if it no longer holds what
    /// the manifest says, the region is downloaded over.
    private static func copyLocalPart(_ local: LocalPart, of chunk: Chunk, into disk: URL) throws -> Bool {
        var hash = SHA256()
        try DiskRegion.write(to: disk, at: chunk.offset, length: UInt64(chunk.length)) { write in
            try DiskRegion.read(local.disk, at: local.offset, length: UInt64(chunk.length)) { piece in
                hash.update(data: piece)
                try write(piece)
            }
        }
        return hash.finalize().ociDigest == chunk.plainDigest
    }

    /// A resumed part that turns out damaged is downloaded once more from the start; a dropped connection or a
    /// busy registry is tried again. Any other failure keeps the part file for the next pull to carry on from.
    private static func download(_ chunk: Chunk, from source: any BlobSource, into receiver: PartReceiver) async throws
    {
        var attempt = 0
        var restarted = false
        while true {
            do {
                try await downloadRest(of: chunk, from: source, into: receiver)
                return
            } catch let error as CorruptPart {
                guard receiver.isResumed, !restarted, !Task.isCancelled else {
                    try? receiver.discard()
                    throw error
                }
                restarted = true
                try receiver.restart()
            } catch let error where TemporaryFailure.isTemporary(error) {
                attempt += 1
                guard attempt < transferAttempts, !Task.isCancelled else { throw error }
                try await Task.sleep(for: TemporaryFailure.retryDelay(attempt: attempt))
            }
        }
    }

    private static func downloadRest(
        of chunk: Chunk, from source: any BlobSource, into receiver: PartReceiver
    ) async throws {
        let start = receiver.received
        if start < chunk.size {
            try await source.streamBlob(chunk.digest, from: start) { answer in
                try receiver.begin(answer, from: start)
            } consume: { data in
                try receiver.write(data)
            }
        }
        try receiver.finish(digest: chunk.digest)
    }

    /// Unpacks a downloaded part straight onto the disk; a part whose contents don't match its manifest fails the
    /// pull, so the image is never recorded with it.
    private static func unpack(_ part: URL, of chunk: Chunk, into disk: URL) throws {
        var hash = SHA256()
        try DiskRegion.write(to: disk, at: chunk.offset, length: UInt64(chunk.length)) { write in
            try decode(part, length: chunk.length) { piece in
                hash.update(data: piece)
                try write(piece)
            }
        }
        guard hash.finalize().ociDigest == chunk.plainDigest else {
            throw HangarError("A disk part unpacked to the wrong contents (\(chunk.digest)).")
        }
    }

    /// Hands the unpacked part over in pieces and refuses one that unpacks to more or fewer bytes than it should.
    static func decode(_ part: URL, length: Int, pieces: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: part)
        defer { try? input.close() }
        var unpacked = 0
        do {
            let filter = try InputFilter(.decompress, using: .lzfse, bufferCapacity: DiskRegion.pieceSize) {
                try input.readPiece(upToCount: $0)
            }
            while let piece = try filter.readData(ofLength: DiskRegion.pieceSize), !piece.isEmpty {
                unpacked += piece.count
                guard unpacked <= length else {
                    throw HangarError("A disk part unpacked to more than \(length) bytes.")
                }
                try pieces(piece)
            }
        } catch is FilterError {
            throw HangarError("A disk part isn't compressed the way Hangar images are.")
        }
        guard unpacked == length else {
            throw HangarError("A disk part unpacked to \(unpacked) bytes instead of \(length).")
        }
    }

    private static func removeOlderImages(named name: String, keeping folder: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for other in folders where other.lastPathComponent != folder.lastPathComponent {
            guard let record = try? JSON.read(Record.self, from: other.appendingPathComponent("image.json")),
                record.name == name
            else { continue }
            removeUnlessInUse(other)
        }
    }

    /// Holds the image's pull lock while it goes, so a pull or a VM creation can't start on it halfway.
    private static func removeUnlessInUse(_ folder: URL) {
        let lock = FileLock(url: folder.appendingPathComponent("pull.lock"))
        guard (try? lock.tryLock(.exclusive)) == true else { return }
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder)
    }
}
