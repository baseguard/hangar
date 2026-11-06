import Darwin
import Foundation
import HangarSupport
import Synchronization

/// A template's `setup` commands, run once in order through Hangar's agent after the VM's first start, as the user the
/// agent runs commands as. Their output goes to the VM's setup.log, so a failed step can be looked into.
package enum SetupSteps {
    package typealias Progress = @Sendable (_ step: Int, _ command: String) -> Void

    /// The end of a failed step's output that its error shows.
    static let shownOutput = 2048
    /// The agent reports that it runs a little before it takes commands.
    static let agentWait = Duration.seconds(120)
    static let agentRetryInterval: TimeInterval = 2

    /// Stops at the first step that fails.
    @concurrent
    package static func run(_ steps: [String], os: GuestOS, in bundle: VMBundle, progress: @escaping Progress)
        async throws
    {
        let log = try openLog(of: bundle)
        defer { try? log.close() }

        for (index, step) in steps.enumerated() {
            progress(index, step)
            write("$ \(step)\n", to: log)
            let (code, output) = try run(step, os: os, in: bundle, log: log)
            guard code == 0 else {
                throw HangarError(
                    "Step \(index + 1) of setting up '\(bundle.name)' failed with code \(code): \(step)\n\(output)\nAll of its output is in \(bundle.setupLogURL.path)."
                )
            }
        }
    }

    /// Runs one command to its end; its exit code and the end of its output.
    private static func run(_ step: String, os: GuestOS, in bundle: VMBundle, log: FileHandle) throws -> (Int32, String)
    {
        let request = ExecRequest(command: os.shellCommand(step), tty: false, interactive: false)
        let descriptor = try openWhenReady(request, in: bundle)
        defer { close(descriptor) }
        let connection = ExecConnection(readFD: descriptor, writeFD: descriptor)

        let tail = Mutex(Data())
        let keep: @Sendable (Data) -> Void = { piece in
            write(piece, to: log)
            tail.withLock { tail in
                tail.append(piece)
                if tail.count > shownOutput { tail = Data(tail.suffix(shownOutput)) }
            }
        }
        var reader = GuestCopy.OutputReader(connection, errors: keep)
        while let piece = try reader.next() { keep(piece) }

        let output = tail.withLock { String(decoding: $0.withoutControlCharacters, as: UTF8.self) }
        return (reader.exitCode ?? 1, output)
    }

    /// Any failure to start the command counts as the agent not being ready, until the wait is over.
    private static func openWhenReady(_ request: ExecRequest, in bundle: VMBundle) throws -> Int32 {
        let deadline = ContinuousClock.now + agentWait
        while true {
            do {
                return try ControlClient.openExec(request, to: bundle)
            } catch  where ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: agentRetryInterval)
            }
        }
    }

    private static func openLog(of bundle: VMBundle) throws -> FileHandle {
        let url = bundle.setupLogURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: url)
        try log.seekToEnd()
        return log
    }

    private static func write(_ text: String, to log: FileHandle) {
        write(Data(text.utf8), to: log)
    }

    private static func write(_ data: Data, to log: FileHandle) {
        try? log.write(contentsOf: data)
    }
}

extension VMBundle {
    package var setupLogURL: URL { url.appendingPathComponent("setup.log") }
}
