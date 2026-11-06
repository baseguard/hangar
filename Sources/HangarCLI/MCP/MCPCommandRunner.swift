import Darwin
import Foundation
import HangarSupport
import Synchronization

/// Runs a tool's `hangar` command as a child of this process and hands back what it printed. Running the command
/// itself, not its code in here, keeps every check and message the same as on the command line.
final class MCPCommandRunner: Sendable {
    enum Stop: Equatable, Sendable {
        case timedOut
        case cancelled
    }

    struct Result: Equatable, Sendable {
        var status: Int32
        var output: String
        /// Why the command was stopped before it ended by itself.
        var stop: Stop?
    }

    /// Only the end is kept; a command's last lines say how it went.
    static let outputLimit = 100_000
    private static let readPiece = 65_536
    /// Each command is a process of its own, so a client's other calls wait their turn.
    private static let maximumRunning = 8

    private let executable: URL
    private let turns: OperationQueue
    /// The requests waiting for their turn; a request cancelled while it waits is taken out and never runs.
    private let queuedRequests = Mutex<Set<String>>([])
    /// The children still running, by the request that started them, so a cancelled request stops its command.
    private let children = Mutex<[String: pid_t]>([:])
    private let stoppedRequests = Mutex<[String: Stop]>([:])

    init(executable: URL) {
        self.executable = executable
        turns = OperationQueue()
        turns.maxConcurrentOperationCount = Self.maximumRunning
    }

    func run(_ invocation: MCPTool.Invocation, for request: String) async -> Result {
        queuedRequests.withLock { _ = $0.insert(request) }
        return await withCheckedContinuation { continuation in
            turns.addOperation {
                continuation.resume(returning: self.runUnlessCancelled(invocation, for: request))
            }
        }
    }

    func cancel(_ request: String) {
        let wasQueued = queuedRequests.withLock { $0.remove(request) != nil }
        guard !wasQueued else { return }
        stop(request, because: .cancelled)
    }

    private func runUnlessCancelled(_ invocation: MCPTool.Invocation, for request: String) -> Result {
        let isStillQueued = queuedRequests.withLock { $0.remove(request) != nil }
        guard isStillQueued else { return Result(status: 1, output: "", stop: .cancelled) }
        return runWaiting(invocation, for: request)
    }

    /// Only a child still running for `request` is stopped; its process ID may belong to another one once it ended.
    private func stop(_ request: String, because reason: Stop) {
        guard let pid = children.withLock({ $0[request] }) else { return }
        stoppedRequests.withLock { $0[request] = reason }
        kill(pid, SIGTERM)
    }

    private func runWaiting(_ invocation: MCPTool.Invocation, for request: String) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: 1, output: "Could not run hangar: \(error.localizedDescription)")
        }
        try? pipe.fileHandleForWriting.close()

        let pid = process.processIdentifier
        children.withLock { $0[request] = pid }
        if let seconds = invocation.timeoutSeconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
                self.stop(request, because: .timedOut)
            }
        }

        let output = Self.readEnd(of: pipe.fileHandleForReading.fileDescriptor)
        process.waitUntilExit()
        children.withLock { $0[request] = nil }
        let stop = stoppedRequests.withLock { $0.removeValue(forKey: request) }
        return Result(status: process.terminationStatus, output: output, stop: stop)
    }

    /// Reads to the end, keeping only the last `outputLimit` bytes, so a flood of output takes no more memory.
    private static func readEnd(of descriptor: Int32) -> String {
        var kept: [UInt8] = []
        var droppedCount = 0
        var buffer = [UInt8](repeating: 0, count: readPiece)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            kept.append(contentsOf: buffer[0..<count])
            if kept.count > outputLimit {
                let extra = kept.count - outputLimit
                droppedCount += extra
                kept.removeFirst(extra)
            }
        }

        let text = String(decoding: kept, as: UTF8.self)
        return droppedCount == 0 ? text : "(the first \(droppedCount) bytes of output are left out)\n" + text
    }
}
