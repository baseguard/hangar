import CryptoKit
import Darwin
import Foundation
import HangarSupport
import Synchronization

final class PartReceiver: Sendable {
    private struct State {
        var handle: FileHandle
        var hash = SHA256()
        var received: Int64 = 0
        var isResumed = false
    }

    private let url: URL
    private let limit: Int64
    private let counter: TransferCounter
    private let state: Mutex<State>

    private init(url: URL, limit: Int64, counter: TransferCounter, state: State) {
        self.url = url
        self.limit = limit
        self.counter = counter
        self.state = Mutex(state)
    }

    /// Carries on from a part file an earlier pull left behind, after reading it back into the digest.
    static func open(_ url: URL, limit: Int64, counter: TransferCounter) throws -> PartReceiver {
        try startOverUnlessResumable(url, limit: limit)
        var state = State(handle: try FileHandle(forUpdating: url))

        while let data = try state.handle.readPiece(upToCount: 1 << 20), !data.isEmpty {
            state.hash.update(data: data)
            state.received += Int64(data.count)
        }

        state.isResumed = state.received > 0
        counter.add(state.received)
        return PartReceiver(url: url, limit: limit, counter: counter, state: state)
    }

    /// An empty part file, or one larger than the part can be, is replaced by a new private one.
    private static func startOverUnlessResumable(_ url: URL, limit: Int64) throws {
        let existing =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard existing == 0 || existing > limit else { return }

        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw HangarError("Could not create \(url.lastPathComponent).")
        }
    }

    var received: Int64 { state.withLock { $0.received } }
    var isResumed: Bool { state.withLock { $0.isResumed } }

    func begin(_ answer: BlobStart, from start: Int64) throws {
        switch answer {
        case .whole:
            try restart()
        case .partial(let offset, let total) where offset == start && total == limit && start > 0:
            state.withLock { $0.isResumed = true }
        default:
            try restart()
            throw TemporaryFailure("A download carried on at the wrong place; starting that part again.")
        }
    }

    func write(_ data: Data) throws {
        try state.withLock { state in
            guard state.received + Int64(data.count) <= limit else {
                throw CorruptPart(message: "A disk part was larger than its manifest says.")
            }
            state.received += Int64(data.count)
            state.hash.update(data: data)
            try state.handle.write(contentsOf: data)
        }
        counter.addDownloaded(Int64(data.count))
    }

    func finish(digest: String) throws {
        try state.withLock { state in
            try state.handle.synchronize()
            guard state.received == limit, state.hash.finalize().ociDigest == digest else {
                throw CorruptPart(message: "A disk part didn't match its digest (\(digest)).")
            }
            try state.handle.close()
        }
    }

    func restart() throws {
        let dropped = try state.withLock { state in
            try state.handle.truncate(atOffset: 0)
            let dropped = state.received
            state = State(handle: state.handle)
            return dropped
        }
        counter.add(-dropped)
    }

    func discard() throws {
        state.withLock { try? $0.handle.close() }
        try FileManager.default.removeItem(at: url)
    }
}

struct CorruptPart: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
