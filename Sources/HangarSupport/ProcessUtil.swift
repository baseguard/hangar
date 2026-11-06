import Darwin
import Foundation
import Synchronization

package enum ProcessUtil {
    package static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    package static func hasExited(_ child: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        return result == child || (result == -1 && errno == ECHILD) || !isAlive(child)
    }

    private static let reaperQueue = DispatchQueue(label: "io.baseguard.hangar.reaper")
    private static let reapers = Mutex<[pid_t: any DispatchSourceProcess]>([:])

    private static func reapWhenDone(_ child: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: reaperQueue)
        let reap: @Sendable () -> Void = {
            var status: Int32 = 0
            guard waitpid(child, &status, WNOHANG) != 0 else { return }
            reapers.withLock { $0.removeValue(forKey: child) }?.cancel()
        }
        source.setEventHandler(handler: reap)
        reapers.withLock { $0[child] = source }
        source.activate()
        reaperQueue.async(execute: reap)
    }

    @discardableResult
    package static func spawnDetached(_ executableURL: URL, arguments: [String], logURL: URL) throws -> pid_t {
        LogFile.moveAsideIfLarge(logURL)
        let executable = executableURL.path
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        resetSignals(in: &attributes)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for argument in argv {
                free(argument)
            }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard status == 0 else { throw HangarError(errno: status, "Could not launch \(executable)") }

        reapWhenDone(pid)
        return pid
    }

    /// A dispatch thread blocks most signals, and a child would keep that mask; so it starts with none blocked.
    private static func resetSignals(in attributes: inout posix_spawnattr_t?) {
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for sig in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaultSignals, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
    }

    @discardableResult
    package static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let errorData = Mutex(Data())
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw failure(of: path, stderr: errorData.withLock { $0 }, status: process.terminationStatus)
        }
        return data
    }

    /// Apple's tools print deprecation warnings on stderr even when they fail for another reason, so those lines
    /// are left out of the message.
    private static func failure(of path: String, stderr: Data, status: Int32) -> HangarError {
        let tool = URL(fileURLWithPath: path).lastPathComponent
        let message = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains("deprecated") }
            .joined(separator: " ")

        return HangarError(message.isEmpty ? "\(tool) failed (exit status \(status))." : "\(tool) failed: \(message)")
    }

    /// The output goes straight to this process's own, so a long job shows its progress as it runs.
    package static func runShowingOutput(_ path: String, _ arguments: [String]) throws {
        let status = try exitStatus(of: path, arguments)
        guard status == 0 else {
            throw HangarError("\(URL(fileURLWithPath: path).lastPathComponent) failed (exit status \(status)).")
        }
    }

    package static func exitStatus(of path: String, _ arguments: [String], quiet: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs `command` (a program and its arguments, no shell) as an administrator through the system's password
    /// dialog, and returns what it printed. Each argument is quoted for the shell that AppleScript starts, so nothing
    /// in it reads as shell syntax. A cancelled dialog or a failed command comes back as an error with its reason.
    @discardableResult
    package static func runAsAdministrator(_ command: [String]) throws -> Data {
        let quotedArguments = command.map { "quoted form of \"\(appleScriptString($0))\"" }
        let script =
            "do shell script \(quotedArguments.joined(separator: " & \" \" & ")) with administrator privileges"
        return try run("/usr/bin/osascript", ["-e", script])
    }

    private static func appleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    package static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}
