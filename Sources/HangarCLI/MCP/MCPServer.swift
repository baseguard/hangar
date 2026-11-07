import Foundation
import HangarSupport
import MCP

/// Hangar's tools over MCP. The SDK answers the handshake, pings and cancellation; Hangar answers the tool list and
/// tool calls, each a `hangar` command.
enum MCPServer {
    static let instructions = """
        Hangar runs macOS, Linux and Windows VMs on this Mac and decides what each can reach on the network. \
        Start a VM with start_vm before run_command or copy_files. Commands run through Hangar's agent in the VM, \
        without SSH.
        """

    static func make(tools: [MCPTool], runner: MCPCommandRunner) async -> Server {
        let server = Server(
            name: "hangar", version: HangarVersion.current, instructions: instructions,
            capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools.map(\.definition))
        }
        await server.withMethodHandler(CallTool.self) { call in
            try await result(of: call, tools: tools, runner: runner)
        }
        return server
    }

    /// A tool's own failure is its result, so the agent reads why; only an unknown tool is a protocol error.
    static func result(
        of call: CallTool.Parameters, tools: [MCPTool], runner: MCPCommandRunner
    ) async throws -> CallTool.Result {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            throw MCPError.invalidParams("Unknown tool \(call.name).")
        }

        let invocation: MCPTool.Invocation
        do {
            invocation = try tool.invocation(MCPArguments(fields: call.arguments ?? [:]))
        } catch {
            return toolResult(error.localizedDescription, isError: true)
        }

        let finished = await runner.run(invocation)
        // A cancelled request gets no answer; the SDK sends none for a handler that ends this way.
        guard finished.stop != .cancelled else { throw CancellationError() }
        return toolResult(report(of: finished, timeout: invocation.timeoutSeconds), isError: finished.status != 0)
    }

    /// What the command printed, and how it ended when that isn't plain success.
    static func report(of finished: MCPCommandRunner.Result, timeout: Int?) -> String {
        var text = finished.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if finished.stop == .timedOut, let timeout {
            text += "\n(stopped after \(timeout) seconds)"
        } else if finished.status != 0 {
            text += "\n(exit code \(finished.status))"
        }
        return text.isEmpty ? "Done." : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolResult(_ text: String, isError: Bool) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }
}
