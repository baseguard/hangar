import CryptoKit
import Darwin
import Foundation
import HangarSupport

/// Updates the agent in a running VM over `hangar exec`: the new agent is copied into the guest's temporary folder, and
/// its own `update` checks the copy's SHA-256, puts itself in place and restarts the agent.
package enum GuestAgentUpdate {
    package enum Step: Sendable {
        case copying
        case starting
        case waitingForRestart
    }

    package typealias Progress = @Sendable (Step) -> Void

    /// The update needs the guest password of the user at the screen; ask for it and run the update again.
    package enum Failure: Error, Equatable, Sendable {
        case passwordNeeded
        case wrongPassword
    }

    /// A guest command said nothing for as long as its wait allows.
    struct Silent: LocalizedError {
        let sentence: String
        var errorDescription: String? { sentence }
    }

    /// The agent restarts within seconds; the rest is room for a slow guest.
    static let restartWait = Duration.seconds(90)
    static let pollInterval = Duration.seconds(1)
    /// Windows' update says nothing until the user at the VM's screen answers its permission prompt.
    static let permissionPromptWait = 5 * 60
    /// Windows' new service takes about 10 seconds to take commands again.
    static let removeAttempts = 8
    static let removeRetryInterval = Duration.seconds(2)
    /// How the agent's `update` starts the sentence it exits with, with code 2 and no prefix, when it needs a password.
    static let passwordNeededPrefix = "A password is needed"
    static let passwordNeededExitCode: Int32 = 2
    /// sudo's own words for a missing or wrong password, in the C locale the Linux command runs in.
    static let sudoPasswordMessages = [
        "a password is required", "no password was provided", "Sorry, try again", "incorrect password",
    ]

    /// A command for the guest and its whole input; nil gives it none.
    struct Command: Equatable {
        var arguments: [String]
        var input: Data?
    }

    /// What a command left: its exit code, nil when the connection ended first, and the start of what it printed.
    struct Finished {
        var exitCode: Int32?
        var output = Data()
        var errors = Data()
    }

    /// How long a command may say nothing, and what the update says when it did.
    struct AnswerWait {
        var seconds: Int
        var silence: String
    }

    /// Only an agent that answers, has `cp-in` to take the new agent and is older than this Hangar's is updated this
    /// way; any other is installed by hand with GuestTools' steps.
    package static func canUpdate(from version: Int?) -> Bool {
        guard let version else { return false }
        return version >= GuestSetup.firstCopyAgentVersion && version < GuestSetup.agentVersion
    }

    /// Cancelling the task stops at once, even on a guest that stopped answering, and the copy is still removed; once
    /// the copy's update has started, the guest finishes it on its own.
    @concurrent
    package static func update(
        _ bundle: VMBundle, os: GuestOS, password: String?, progress: @escaping Progress = { _ in }
    ) async throws {
        let feature = "Updating the agent from Hangar"
        let installed = try GuestCopy.checkAgent(of: bundle, needs: GuestSetup.firstCopyAgentVersion, for: feature)
        guard installed < GuestSetup.agentVersion else { return }
        let passwordLine = try passwordLine(of: password)
        let stop = CopyStop()

        try await withTaskCancellationHandler {
            try await copyAndInstall(in: bundle, os: os, passwordLine: passwordLine, stop: stop, progress: progress)
        } onCancel: {
            stop.stop()
        }
    }

    /// Copies the new agent in, starts its update and waits for the new agent; the copy is removed however that ends.
    private static func copyAndInstall(
        in bundle: VMBundle, os: GuestOS, passwordLine: Data?, stop: CopyStop, progress: Progress
    ) async throws {
        progress(.copying)
        let agent = try GuestTools.agentFile(for: os)
        let agentSHA256 = try sha256(of: agent)
        let copy = try copyPath(for: os, in: bundle, stop: stop)

        do {
            // cp-in writes straight to `copy`, so a copy that stops part way leaves a cut-off file there.
            try copyNewAgent(agent, to: copy, in: bundle, stop: stop)
            progress(.starting)
            let command = updateCommand(for: os, agent: copy, sha256: agentSHA256, passwordLine: passwordLine)
            try startUpdate(command, os: os, gavePassword: passwordLine != nil, in: bundle, stop: stop)
            progress(.waitingForRestart)
            try await waitForNewAgent(in: bundle)
        } catch {
            await removeCopy(copy, os: os, in: bundle)
            throw error
        }
        await removeCopy(copy, os: os, in: bundle)
    }

    /// The guest's `update` installs the copy only if it still has these bytes.
    static func sha256(of agent: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: agent)
        } catch {
            throw HangarError("Could not read Hangar's agent at \(agent.path): \(error.localizedDescription)")
        }
        return SHA256.hash(data: data).hex
    }

    /// Runs the copy's `update`, which returns once the update has started and finishes on its own.
    private static func startUpdate(
        _ command: Command, os: GuestOS, gavePassword: Bool, in bundle: VMBundle, stop: CopyStop
    ) throws {
        let finished = try run(command, in: bundle, stop: stop, wait: startWait(on: os, vm: bundle.name))
        if let problem = problem(of: finished, gavePassword: gavePassword, vm: bundle.name) { throw problem }
    }

    /// Windows' update waits for the user at the VM's screen to allow it; elsewhere it answers within moments.
    static func startWait(on os: GuestOS, vm: String) -> AnswerWait {
        switch os {
        case .linux, .macOS:
            return usualWait(vm: vm)
        case .windows:
            let silence =
                "'\(vm)' didn't answer; if Windows shows a permission prompt in the VM, click Yes, then try again."
            return AnswerWait(seconds: permissionPromptWait, silence: silence)
        }
    }

    private static func usualWait(vm: String) -> AnswerWait {
        AnswerWait(seconds: GuestCopy.receiveTimeout, silence: "'\(vm)' stopped answering during the agent's update.")
    }

    /// The password and the newline sudo and the agent read it up to; it goes only to the command's input.
    private static func passwordLine(of password: String?) throws -> Data? {
        guard let password else { return nil }
        guard !password.contains(where: \.isNewline) else {
            throw HangarError("A password with a line break can't be given to the guest.")
        }
        let line = Data((password + "\n").utf8)
        guard line.count <= ExecFrame.maximumPayload else { throw HangarError("The password is too long.") }
        return line
    }

    private static func copyNewAgent(_ agent: URL, to path: String, in bundle: VMBundle, stop: CopyStop) throws {
        _ = try GuestFileBrowser.withGuestReason(in: bundle, forAnyFailure: false) { errors in
            try GuestCopy.copyIn(agent, to: path, in: bundle, errors: errors, stop: stop)
        }
    }

    /// Windows takes a program whose name has "update", "setup" or "install" in it for an installer and starts it only
    /// elevated (error 740), so the copy's name has none of them.
    private static func copyPath(for os: GuestOS, in bundle: VMBundle, stop: CopyStop) throws -> String {
        // A fresh name, so nothing already in the guest's temporary folder can stand in for the new agent.
        let name = "hangar-agent-new-\(UUID().uuidString)"
        switch os {
        case .linux, .macOS:
            return "/tmp/" + name
        case .windows:
            let folder = try windowsTempFolder(of: bundle, stop: stop)
            return GuestFileBrowser.path(of: name + ".exe", in: folder, os: .windows)
        }
    }

    private static func windowsTempFolder(of bundle: VMBundle, stop: CopyStop) throws -> String {
        let echo = Command(arguments: GuestOS.windows.shellCommand("echo %TEMP%"), input: nil)
        let finished = try run(echo, in: bundle, stop: stop, wait: usualWait(vm: bundle.name))
        guard finished.exitCode == 0, let folder = windowsTempFolder(from: finished.output) else {
            throw HangarError("'\(bundle.name)' didn't name a temporary folder to copy the new agent to.")
        }
        return folder
    }

    /// The folder `echo %TEMP%` printed, if it is a plain absolute path: removing the copy runs it through cmd.
    static func windowsTempFolder(from output: Data) -> String? {
        let folder = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Array(folder.prefix(3))
        guard start.count == 3, start[0].isASCII, start[0].isLetter, start[1] == ":", start[2] == "\\" else {
            return nil
        }
        let cmdCharacters = Set(#""%^&|<>!"#)
        let hasControlCharacter = folder.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !hasControlCharacter, !folder.contains(where: cmdCharacters.contains) else { return nil }
        return folder
    }

    /// `sha256` is the lowercase hex of the agent this Mac copied to `path`.
    static func updateCommand(for os: GuestOS, agent path: String, sha256: String, passwordLine: Data?) -> Command {
        let update = [path, "update", "--sha256", sha256]
        switch os {
        case .linux:
            // sudo's messages in English tell a missing or wrong password apart from any other failure.
            let sudo = ["/usr/bin/env", "LC_ALL=C", "sudo"]
            guard let passwordLine else {
                return Command(arguments: sudo + ["-n", "--"] + update, input: nil)
            }
            return Command(arguments: sudo + ["-S", "-p", "", "--"] + update, input: passwordLine)
        case .macOS:
            return Command(arguments: update, input: passwordLine ?? Data())
        case .windows:
            return Command(arguments: update, input: nil)
        }
    }

    /// Why the update didn't start, or nil when it did. A connection that ended without an exit was cut by the
    /// agent's restart, so the update ran.
    static func problem(of finished: Finished, gavePassword: Bool, vm: String) -> (any Error)? {
        guard let exitCode = finished.exitCode, exitCode != 0 else { return nil }
        let sentence = GuestFileBrowser.guestSentence(finished.errors, vm: vm)?.message ?? ""
        if isAboutPassword(sentence, exitCode: exitCode) {
            return gavePassword ? Failure.wrongPassword : Failure.passwordNeeded
        }
        guard !sentence.isEmpty else {
            return HangarError("The agent in '\(vm)' couldn't start its update (exit code \(exitCode)).")
        }
        return HangarError(sentence)
    }

    private static func isAboutPassword(_ sentence: String, exitCode: Int32) -> Bool {
        if exitCode == passwordNeededExitCode, sentence.hasPrefix(passwordNeededPrefix) { return true }
        return sudoPasswordMessages.contains { sentence.contains($0) }
    }

    /// Polled: the VM's report changes only once the new agent has started and sent its first one.
    private static func waitForNewAgent(in bundle: VMBundle) async throws {
        let deadline = ContinuousClock.now + restartWait
        while ContinuousClock.now < deadline {
            guard bundle.isRunning else {
                throw HangarError("'\(bundle.name)' stopped while its agent was being updated.")
            }
            if let version = reportedVersion(of: bundle), version >= GuestSetup.agentVersion { return }
            try await Task.sleep(for: pollInterval)
        }
        throw HangarError(
            "The agent in '\(bundle.name)' didn't come back after the update; restart the VM or run "
                + "hangar setup \(bundle.name).")
    }

    /// Nil while the VM's process has no report to give, as when the agent restarts.
    private static func reportedVersion(of bundle: VMBundle) -> Int? {
        guard case .report(let report)? = try? ControlClient.send(.memory, to: bundle, timeout: 1) else { return nil }
        return report?.agentVersion
    }

    /// Best effort, with a stop of its own so it runs after a Cancel too. Right after an update, Windows' exec can say
    /// nobody is signed in while the new service starts its session helper, so a refused command is tried again.
    private static func removeCopy(_ path: String, os: GuestOS, in bundle: VMBundle) async {
        let arguments =
            switch os {
            case .linux, .macOS: ["rm", "-f", "--", path]
            case .windows: ["cmd.exe", "/d", "/c", "del", "/f", "/q", path]
            }
        let remove = Command(arguments: arguments, input: nil)
        for _ in 0..<removeAttempts {
            do {
                _ = try run(remove, in: bundle, stop: CopyStop(), wait: usualWait(vm: bundle.name))
                return
            } catch is Silent {
                return
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: removeRetryInterval)
            }
        }
    }

    /// Runs `command` in the guest. `stop` ends it at once with a CancellationError; a guest that says nothing for as
    /// long as `wait` allows ends it with `wait`'s sentence.
    private static func run(_ command: Command, in bundle: VMBundle, stop: CopyStop, wait: AnswerWait) throws
        -> Finished
    {
        let request = ExecRequest(command: command.arguments, tty: false, interactive: command.input != nil)
        let descriptor = try ControlClient.openExec(request, to: bundle)
        GuestCopy.limitWait(SO_RCVTIMEO, of: descriptor, to: wait.seconds)
        stop.watch(descriptor)
        defer { stop.close(descriptor) }
        let connection = ExecConnection(readFD: descriptor, writeFD: descriptor)

        do {
            if let input = command.input {
                try send(input, over: connection)
            }
            let finished = try readToEnd(connection)
            guard !stop.isStopped else { throw CancellationError() }
            return finished
        } catch {
            if stop.isStopped || Task.isCancelled { throw CancellationError() }
            if error is ExecConnection.StoppedAnswering { throw Silent(sentence: wait.silence) }
            throw error
        }
    }

    /// An empty input frame ends the input, so empty input sends only that.
    private static func send(_ input: Data, over connection: ExecConnection) throws {
        if !input.isEmpty {
            try connection.send(ExecFrame(.input, payload: input))
        }
        try connection.send(ExecFrame(.input, payload: Data()))
    }

    /// A stop shuts the connection down, which ends this like the agent's restart does; `run` tells the two apart.
    private static func readToEnd(_ connection: ExecConnection) throws -> Finished {
        var finished = Finished()
        while let frame = try connection.receive() {
            switch frame.kind {
            case .output: keepStart(of: frame.payload, in: &finished.output)
            case .errorOutput: keepStart(of: frame.payload, in: &finished.errors)
            case .exit:
                finished.exitCode = frame.exitCode ?? 1
                return finished
            case .failed: throw HangarError(frame.message)
            case .start, .input, .resize: continue
            }
        }
        return finished
    }

    /// A guest can't fill this Mac's memory: only the start of what it prints is kept.
    private static func keepStart(of piece: Data, in kept: inout Data) {
        kept.append(piece.prefix(max(0, GuestDrop.reasonLimit - kept.count)))
    }
}

extension GuestAgentUpdate.Step {
    /// What the app and `hangar setup` show while the step runs.
    package func message(os: GuestOS, vm: String) -> String {
        switch self {
        case .copying:
            "Copying Hangar's new agent into “\(vm)”…"
        case .starting:
            os == .windows
                ? "Click Yes in “\(vm)” to let Hangar update its agent." : "Updating Hangar's agent in “\(vm)”…"
        case .waitingForRestart:
            "Waiting for Hangar's agent in “\(vm)” to restart…"
        }
    }

    /// While the Mac waits for the restart, the guest finishes the update on its own, so it can't be cancelled.
    package var canCancel: Bool {
        switch self {
        case .copying, .starting: true
        case .waitingForRestart: false
        }
    }
}
