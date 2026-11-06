import ArgumentParser
import Foundation
import HangarSupport
import MCP

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

        runMain {
            let server = await MCPServer.make(tools: MCPTools.all, runner: runner)
            try await server.start(transport: MCPStdioTransport())
            await server.waitUntilCompleted()
        }
    }
}
