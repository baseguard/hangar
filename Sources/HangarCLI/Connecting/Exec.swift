import ArgumentParser
import Darwin
import Foundation
import HangarKit
import HangarSupport

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in a running VM through Hangar's agent, without SSH.",
        discussion: """
            Examples:
              hangar exec mac uname -a
                  Run a command and print its output.
              hangar exec -it mac zsh
                  Open a shell in the VM.
              hangar exec -i deb -- sh -c 'cat > notes.txt' < notes.txt
                  Send a file to the command's input.
            The command runs as the user at the VM's screen, or as the VM's
            own account when nobody is signed in. It needs Hangar's agent 17
            or later in the VM. hangar exec exits with the command's exit code,
            or 125 when the command couldn't run.
            """
    )

    /// The command never ran, or its end never arrived.
    static let couldNotRunCode: Int32 = 125

    @Flag(name: .customShort("i"), help: "Send this terminal's input to the command.")
    var interactive = false

    @Flag(name: .customShort("t"), help: "Give the command a terminal, for shells and full-screen programs.")
    var tty = false

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("The command and its arguments.", valueName: "command"))
    var command: [String] = []

    private var program: [String] { command.first == "--" ? Array(command.dropFirst()) : command }

    func validate() throws {
        guard !program.isEmpty else { throw ValidationError("Give the command to run after the VM's name.") }
    }

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        guard bundle.isRunning else { throw HangarError("'\(name)' isn't running. Start it: hangar run \(name)") }

        let size = Self.terminalSize()
        let request = ExecRequest(
            command: program, tty: tty, interactive: interactive, columns: size.columns, rows: size.rows)
        let fd: Int32
        do {
            fd = try ControlClient.openExec(request, to: bundle)
        } catch {
            printError("Error: \(error.localizedDescription)")
            Foundation.exit(Self.couldNotRunCode)
        }
        let connection = ExecConnection(readFD: fd, writeFD: fd)

        if tty { RawTerminal.enable() }
        if interactive { Self.forwardInput(to: connection) }
        let resizes = tty ? Self.forwardTerminalSize(to: connection) : nil
        let code = withExtendedLifetime(resizes) { printOutput(from: connection) }
        RawTerminal.restore()
        Foundation.exit(code)
    }

    /// Writes the command's output as it comes and returns its exit code.
    private func printOutput(from connection: ExecConnection) -> Int32 {
        do {
            while let frame = try connection.receive() {
                if let code = handle(frame) { return code }
            }
        } catch {
            RawTerminal.restore()
            printError("Error: \(error.localizedDescription)")
            return Self.couldNotRunCode
        }

        RawTerminal.restore()
        printError("Error: '\(name)' stopped answering before the command finished.")
        return Self.couldNotRunCode
    }

    /// Writes a frame's output; the exit code once the command is done.
    private func handle(_ frame: ExecFrame) -> Int32? {
        switch frame.kind {
        case .output:
            try? FileHandle.standardOutput.write(contentsOf: frame.payload)
            return nil
        case .errorOutput:
            try? FileHandle.standardError.write(contentsOf: frame.payload)
            return nil
        case .exit:
            return frame.exitCode ?? Self.couldNotRunCode
        case .failed:
            RawTerminal.restore()
            printError("Error: \(frame.message)")
            return Self.couldNotRunCode
        case .start, .input, .resize:
            return nil
        }
    }

    /// Sends this process's input until it ends, then an empty input frame, which closes the command's input.
    private static func forwardInput(to connection: ExecConnection) {
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: ExecFrame.maximumPayload)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                let payload = Data(chunk[0..<max(count, 0)])
                guard (try? connection.send(ExecFrame(.input, payload: payload))) != nil, count > 0 else { return }
            }
        }
    }

    private static func forwardTerminalSize(to connection: ExecConnection) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler {
            let size = terminalSize()
            try? connection.send(.resize(columns: size.columns, rows: size.rows))
        }
        source.resume()
        return source
    }

    private static func terminalSize() -> (columns: UInt16, rows: UInt16) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return (ExecRequest.defaultColumns, ExecRequest.defaultRows)
        }
        return (size.ws_col, size.ws_row)
    }
}
