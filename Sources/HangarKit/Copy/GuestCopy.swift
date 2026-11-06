import Darwin
import Foundation
import HangarSupport
import Synchronization

/// `hangar cp`'s two directions over `hangar exec`: the Mac runs the guest agent's own `cp-in` or `cp-out` as the user
/// at the VM's screen and streams `CopyArchive` through the command's input or output. Only the Mac starts a copy.
package enum GuestCopy {
    /// What the agent writes on its error output, as it comes: why it failed, or how many links it left out.
    package typealias ErrorOutput = @Sendable (Data) -> Void

    package struct Outcome: Equatable, Sendable {
        package var files = 0
        package var skipped = 0
    }

    /// The agent's commands for `feature` came with `version`; an older agent is told to update before anything is sent.
    /// Returns the version the agent reports.
    @discardableResult
    package static func checkAgent(of bundle: VMBundle, needs version: Int, for feature: String) throws -> Int {
        guard bundle.isRunning else {
            throw HangarError("'\(bundle.name)' isn't running. Start it: hangar run \(bundle.name)")
        }
        let reply = try ControlClient.send(.memory, to: bundle)
        guard case .report(let report) = reply, let installed = report?.agentVersion else {
            throw HangarError("'\(bundle.name)' has no agent answering yet. Wait until it has started.")
        }
        guard installed >= version else {
            throw HangarError(
                "'\(bundle.name)' has Hangar's agent \(installed); \(feature) needs \(version) or later. Update it with "
                    + "Virtual Machine › Update Guest Agent… or hangar setup \(bundle.name).")
        }
        return installed
    }

    /// A guest that stops reading the archive fails the copy instead of holding it.
    static let sendTimeout = 30
    /// A guest that sends nothing for this long while its files are copied out is stuck, not reading a slow disk.
    static let receiveTimeout = 60
    /// The agent writes as it reads, so once the archive is in it ends within moments; this is room for a slow disk.
    static let endTimeout: DispatchTimeInterval = .seconds(60)

    /// Copies a file or folder on this Mac to `guestPath`: into it when it is a folder there,
    /// otherwise under its name. Returns how many links or special files were left out. `sent` counts the archive's
    /// bytes as they go; a cancelled task, or `stop` from another thread, ends the copy with a CancellationError.
    package static func copyIn(
        _ item: URL, to guestPath: String, in bundle: VMBundle, errors: @escaping ErrorOutput,
        stop: CopyStop = CopyStop(), sent: @escaping (Int) -> Void = { _ in }
    ) throws -> Int {
        let (connection, descriptor) = try open(["cp-in", guestPath], sendsInput: true, in: bundle)
        // No receive limit: the agent says nothing while it takes the archive, however long that runs.
        limitWait(SO_SNDTIMEO, of: descriptor, to: sendTimeout)
        return try run(over: descriptor, vm: bundle.name, stop: stop) {
            try sendArchive(of: item, over: connection, descriptor: descriptor, in: bundle, errors: errors, sent: sent)
        }
    }

    /// Returns how many links or special files were left out.
    private static func sendArchive(
        of item: URL, over connection: ExecConnection, descriptor: Int32, in bundle: VMBundle,
        errors: @escaping ErrorOutput, sent: @escaping (Int) -> Void
    ) throws -> Int {
        let exit = Exit(reading: descriptor, errors: errors)
        var writer = CopyArchiveWriter { piece in
            try Task.checkCancellation()
            try connection.send(ExecFrame(.input, payload: piece))
            sent(piece.count)
        }
        do {
            try writer.write(item, as: item.lastPathComponent)
            try writer.finish()
            try connection.send(ExecFrame(.input, payload: Data()))
        } catch {
            // A guest that stopped taking the archive won't take its end either.
            if !(error is ExecConnection.StoppedAnswering) { try? endAfterFailure(connection, exit, in: bundle) }
            throw error
        }
        try exit.wait(in: bundle, upTo: endTimeout)
        return writer.skipped
    }

    /// Copies `guestPath` in the VM into `parent` on this Mac as `name`, which the Mac picks, never the guest.
    /// `received` counts the archive's bytes as they come; a cancelled task, or `stop` from another thread, ends the
    /// copy with a CancellationError.
    package static func copyOut(
        _ guestPath: String, into parent: URL, as name: String, in bundle: VMBundle, errors: @escaping ErrorOutput,
        stop: CopyStop = CopyStop(), received: @escaping (Int) -> Void = { _ in }
    ) throws -> Outcome {
        let (_, descriptor) = try open(["cp-out", guestPath], sendsInput: false, in: bundle)
        return try copyOut(
            over: descriptor, into: parent, as: name, in: bundle, errors: errors, stop: stop, received: received)
    }

    /// The copy out over the agent's connection, which it closes; closing it on a refusal stops the agent where it is.
    static func copyOut(
        over descriptor: Int32, into parent: URL, as name: String, in bundle: VMBundle, errors: @escaping ErrorOutput,
        stop: CopyStop, receiveTimeout: Int = receiveTimeout, received: @escaping (Int) -> Void = { _ in }
    ) throws -> Outcome {
        limitWait(SO_RCVTIMEO, of: descriptor, to: receiveTimeout)
        return try run(over: descriptor, vm: bundle.name, stop: stop) {
            let connection = ExecConnection(readFD: descriptor, writeFD: descriptor)
            var output = OutputReader(connection, errors: errors)
            var extractor = try CopyExtractor(into: parent, as: name)
            defer { extractor.close() }

            var reader = CopyArchiveReader {
                try Task.checkCancellation()
                let piece = try output.next()
                received(piece?.count ?? 0)
                return piece
            }
            try extractor.extract(from: &reader)
            try output.finish(in: bundle)
            return Outcome(files: extractor.summary.files, skipped: extractor.summary.skipped)
        }
    }

    /// `hangar cp - vm:dest`: the archive comes from `input` as it is, unchecked; the user chose that.
    package static func streamIn(
        from input: Int32, to guestPath: String, in bundle: VMBundle, errors: @escaping ErrorOutput
    )
        throws
    {
        let (connection, descriptor) = try open(["cp-in", guestPath], sendsInput: true, in: bundle)
        limitWait(SO_SNDTIMEO, of: descriptor, to: sendTimeout)
        try run(over: descriptor, vm: bundle.name, stop: CopyStop()) {
            try send(from: input, over: connection, descriptor: descriptor, in: bundle, errors: errors)
        }
    }

    private static func send(
        from input: Int32, over connection: ExecConnection, descriptor: Int32, in bundle: VMBundle,
        errors: @escaping ErrorOutput
    ) throws {
        let exit = Exit(reading: descriptor, errors: errors)
        var buffer = [UInt8](repeating: 0, count: ExecFrame.maximumPayload)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                let reason = HangarError(errno: errno, "Could not read the archive")
                try? endAfterFailure(connection, exit, in: bundle)
                throw reason
            }
            let piece = Data(buffer[0..<count])
            guard (try? connection.send(ExecFrame(.input, payload: piece))) != nil, count > 0 else { break }
        }
        try exit.wait(in: bundle, upTo: endTimeout)
    }

    /// After a failure here: ends the agent's input, so it stops reading and exits, and waits for that. The agent's
    /// own reason has gone to `errors` already; the caller throws this Mac's.
    private static func endAfterFailure(_ connection: ExecConnection, _ exit: Exit, in bundle: VMBundle) throws {
        try? connection.send(ExecFrame(.input, payload: Data()))
        try exit.wait(in: bundle, upTo: endTimeout)
    }

    /// `hangar cp vm:src -`: the archive goes to `output` as the VM sent it, unchecked; the user chose that.
    package static func streamOut(
        _ guestPath: String, to output: Int32, in bundle: VMBundle, errors: @escaping ErrorOutput
    )
        throws
    {
        let (connection, descriptor) = try open(["cp-out", guestPath], sendsInput: false, in: bundle)
        limitWait(SO_RCVTIMEO, of: descriptor, to: receiveTimeout)
        try run(over: descriptor, vm: bundle.name, stop: CopyStop()) {
            var reader = OutputReader(connection, errors: errors)
            while let piece = try reader.next() {
                try writeAll(piece, to: output)
            }
            try reader.finish(in: bundle)
        }
    }

    /// A send or receive on `descriptor` that waits longer than `seconds` fails with StoppedAnswering.
    static func limitWait(_ option: Int32, of descriptor: Int32, to seconds: Int) {
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, option, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Runs one copy over the agent's connection and closes it after. A copy that `stop` or a cancelled task ended
    /// throws a CancellationError, and one whose guest stopped answering says so with the VM's name and `activity`.
    static func run<T>(
        over descriptor: Int32, vm: String, stop: CopyStop, activity: String = "the copy", _ copy: () throws -> T
    ) throws -> T {
        stop.watch(descriptor)
        defer { stop.close(descriptor) }
        do {
            return try copy()
        } catch {
            throw copyError(for: error, stop: stop, vm: vm, activity: activity)
        }
    }

    /// After a stop, the shut-down connection fails a read or write with an error that isn't the cause.
    private static func copyError(for error: any Error, stop: CopyStop, vm: String, activity: String) -> any Error {
        if stop.isStopped || Task.isCancelled { return CancellationError() }
        if error is ExecConnection.StoppedAnswering {
            return HangarError("'\(vm)' stopped answering during \(activity).")
        }
        return error
    }

    /// The agent's own subcommand; the agent runs its own program for the name `hangar-agent`.
    static func open(_ arguments: [String], sendsInput: Bool, in bundle: VMBundle) throws
        -> (ExecConnection, Int32)
    {
        let request = ExecRequest(command: ["hangar-agent"] + arguments, tty: false, interactive: sendsInput)
        let descriptor = try ControlClient.openExec(request, to: bundle)
        return (ExecConnection(readFD: descriptor, writeFD: descriptor), descriptor)
    }

    /// What a copy throws when the agent's command failed; the agent's own reason has gone to `errors`.
    struct CopyFailed: LocalizedError {
        let vm: String
        var errorDescription: String? { "The copy failed in '\(vm)'." }
    }

    private static func writeAll(_ data: Data, to output: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(output, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw HangarError(errno: errno, "Could not write the copy")
                }
                offset += count
            }
        }
    }
}

extension GuestCopy {
    /// The command's output as the archive's bytes; its error output goes on to `errors` as it comes.
    struct OutputReader {
        private let connection: ExecConnection
        private let errors: ErrorOutput
        private(set) var exitCode: Int32?

        init(_ connection: ExecConnection, errors: @escaping ErrorOutput) {
            self.connection = connection
            self.errors = errors
        }

        /// The next bytes of output; nil once the command has ended. The agent sends the exit after all of its
        /// output, and keeps the connection open until the Mac leaves, so the exit is the end.
        mutating func next() throws -> Data? {
            while exitCode == nil {
                guard let frame = try connection.receive() else {
                    throw HangarError("The VM stopped answering before the copy finished.")
                }
                switch frame.kind {
                case .output: return frame.payload
                case .errorOutput: errors(frame.payload.withoutControlCharacters)
                case .exit: exitCode = frame.exitCode ?? 1
                case .failed: throw HangarError(frame.message)
                case .start, .input, .resize: continue
                }
            }
            return nil
        }

        /// Waits for the command's end after the archive's, and fails when the agent did.
        mutating func finish(in bundle: VMBundle) throws {
            while try next() != nil {}
            guard exitCode == 0 else { throw GuestCopy.CopyFailed(vm: bundle.name) }
        }
    }

    /// The command's end, read on its own thread while the archive goes in, so the agent's errors are never stuck
    /// behind a full input.
    final class Exit: Sendable {
        private let code = Mutex<Result<Int32, HangarError>?>(nil)
        private let ended = DispatchSemaphore(value: 0)

        /// Reads its own copy of `descriptor`: the copy may close `descriptor` while this thread lives on, and a read
        /// on its number could then take another connection's bytes. Shutting down `descriptor` still ends it.
        init(reading descriptor: Int32, errors: @escaping ErrorOutput) {
            let ownDescriptor = dup(descriptor)
            Thread.detachNewThread { self.read(ownDescriptor, errors: errors) }
        }

        private func read(_ descriptor: Int32, errors: @escaping ErrorOutput) {
            defer { if descriptor >= 0 { close(descriptor) } }
            let connection = ExecConnection(readFD: descriptor, writeFD: descriptor)
            var reader = OutputReader(connection, errors: errors)
            let result: Result<Int32, HangarError>
            do {
                while try reader.next() != nil {}
                result = .success(reader.exitCode ?? 1)
            } catch {
                result = .failure(error as? HangarError ?? HangarError(error.localizedDescription))
            }
            code.withLock { $0 = result }
            ended.signal()
        }

        func wait(in bundle: VMBundle, upTo timeout: DispatchTimeInterval) throws {
            guard ended.wait(timeout: .now() + timeout) == .success else {
                throw HangarError("'\(bundle.name)' didn't finish taking the files.")
            }
            let result = code.withLock { $0 } ?? .success(1)
            guard try result.get() == 0 else { throw GuestCopy.CopyFailed(vm: bundle.name) }
        }
    }
}
