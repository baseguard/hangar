import ArgumentParser
import Foundation
import HangarSupport
import Synchronization

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Let AI agents like Claude Code and Codex use Hangar, as an MCP server.",
        discussion: """
            Examples:
              claude mcp add hangar -- hangar mcp
                  Add Hangar to Claude Code.
              codex mcp add hangar -- hangar mcp
                  Add Hangar to Codex.

            The agent client starts it and talks to it over stdin and stdout. Its tools \
            create, start and stop VMs, run commands and copy files in them, take \
            snapshots and change traffic rules, through the same commands as here. \
            Secret values, passwords and deleting VMs stay with you.
            """
    )

    func run() throws {
        guard let executable = Bundle.main.executableURL else { throw HangarError("Could not find hangar itself.") }
        let runner = MCPCommandRunner(executable: executable)
        let server = MCPServer(
            tools: MCPTools.all, run: { await runner.run($0, for: $1) }, cancel: { runner.cancel($0) })
        let output = Mutex(FileHandle.standardOutput)

        @Sendable func reply(to line: MCPLine) async {
            guard let answer = await server.answer(line) else { return }
            output.withLock { try? $0.write(contentsOf: Data((answer + "\n").utf8)) }
        }

        // Calls run side by side, and the ones still running when the client closes stdin get their answers.
        runMain {
            try await withThrowingDiscardingTaskGroup { calls in
                var lines = MCPLineSplitter()
                for try await byte in FileHandle.standardInput.bytes {
                    guard let line = lines.add(byte) else { continue }
                    calls.addTask { await reply(to: line) }
                }
                if let last = lines.finish() { calls.addTask { await reply(to: last) } }
            }
        }
    }
}
