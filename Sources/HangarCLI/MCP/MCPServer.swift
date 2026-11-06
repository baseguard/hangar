import Foundation
import HangarSupport

/// Answers an MCP client's JSON-RPC messages, one line each: the handshake, the tool list and tool calls.
final class MCPServer: Sendable {
    typealias Run = @Sendable (MCPTool.Invocation, _ request: String) async -> MCPCommandRunner.Result

    static let latestVersion = "2025-06-18"
    static let knownVersions: Set<String> = [latestVersion, "2025-03-26", "2024-11-05"]

    static let instructions = """
        Hangar runs macOS, Linux and Windows VMs on this Mac and decides what each can reach on the network. \
        Start a VM with start_vm before run_command or copy_files. Commands run through Hangar's agent in the VM, \
        without SSH.
        """

    private let tools: [MCPTool]
    private let run: Run
    private let cancel: @Sendable (_ request: String) -> Void

    init(tools: [MCPTool], run: @escaping Run, cancel: @escaping @Sendable (String) -> Void) {
        self.tools = tools
        self.run = run
        self.cancel = cancel
    }

    private struct Message: Decodable {
        var id: JSONValue?
        var method: String?
        var params: JSONValue?
    }

    private struct ProtocolError: Error {
        var code: Int
        var message: String

        static func unknownMethod(_ method: String) -> ProtocolError {
            ProtocolError(code: -32601, message: "Unknown method \(method).")
        }

        static let badRequestID = ProtocolError(code: -32600, message: "A request ID must be a string or a number.")

        static var lineTooLong: ProtocolError {
            let limit = ByteSize.format(UInt64(MCPLineSplitter.maximumLength))
            return ProtocolError(code: -32600, message: "A message can be at most \(limit).")
        }
    }

    /// The client cancelled the request, so it waits for no answer.
    private struct Cancelled: Error {}

    /// The answer to one line, or nil for a notification or a client's reply, which get none.
    func answer(_ line: MCPLine) async -> String? {
        switch line {
        case .message(let text):
            return await answer(message: text)
        case .tooLong:
            return failure(id: .null, .lineTooLong)
        }
    }

    private func answer(message line: String) async -> String? {
        guard let message = try? JSON.decoder.decode(Message.self, from: Data(line.utf8)) else {
            return failure(id: .null, ProtocolError(code: -32700, message: "Not JSON-RPC."))
        }
        guard let method = message.method else { return nil }
        guard let id = message.id else {
            notice(method, message.params)
            return nil
        }
        // An ID of another kind would match no request when the client cancels one.
        guard let request = Self.key(id) else {
            return failure(id: .null, .badRequestID)
        }

        do {
            let result = try await result(of: method, params: message.params ?? [:], request: request)
            return encoded(["jsonrpc": "2.0", "id": id, "result": result])
        } catch is Cancelled {
            return nil
        } catch let error as ProtocolError {
            return failure(id: id, error)
        } catch {
            return failure(id: id, ProtocolError(code: -32603, message: "Internal error."))
        }
    }

    private func failure(id: JSONValue, _ error: ProtocolError) -> String {
        let details: JSONValue = ["code": .number(Double(error.code)), "message": .string(error.message)]
        return encoded(["jsonrpc": "2.0", "id": id, "error": details])
    }

    private func notice(_ method: String, _ params: JSONValue?) {
        guard method == "notifications/cancelled", let id = params?["requestId"], let request = Self.key(id) else {
            return
        }
        cancel(request)
    }

    private func result(of method: String, params: JSONValue, request: String) async throws -> JSONValue {
        switch method {
        case "initialize": return handshake(params)
        case "ping": return [:]
        case "tools/list": return ["tools": .array(tools.map(\.definition))]
        case "tools/call": return try await call(params, request: request)
        default: throw ProtocolError.unknownMethod(method)
        }
    }

    /// The client's version when Hangar speaks it, else the latest, which the client may refuse.
    private func handshake(_ params: JSONValue) -> JSONValue {
        let asked = params["protocolVersion"]?.string ?? Self.latestVersion
        let version = Self.knownVersions.contains(asked) ? asked : Self.latestVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "hangar", "version": .string(HangarVersion.current)],
            "instructions": .string(Self.instructions),
        ]
    }

    /// A tool's own failure is its result, so the agent reads why; only an unknown tool is a protocol error.
    private func call(_ params: JSONValue, request: String) async throws -> JSONValue {
        guard let name = params["name"]?.string, let tool = tools.first(where: { $0.name == name }) else {
            throw ProtocolError(code: -32602, message: "Unknown tool \(params["name"]?.string ?? "").")
        }
        guard case .object(let fields) = params["arguments"] ?? [:] else {
            return Self.toolResult("The arguments must be an object.", isError: true)
        }

        let invocation: MCPTool.Invocation
        do {
            invocation = try tool.invocation(MCPArguments(fields: fields))
        } catch {
            return Self.toolResult(error.localizedDescription, isError: true)
        }
        let finished = await run(invocation, request)
        guard finished.stop != .cancelled else { throw Cancelled() }
        return Self.toolResult(
            Self.report(of: finished, timeout: invocation.timeoutSeconds), isError: finished.status != 0)
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

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    /// A request's ID as one string, whether the client sent a number or a string; nil for any other kind.
    private static func key(_ id: JSONValue) -> String? {
        switch id {
        case .string(let text): "s:" + text
        case .number(let number): "n:\(number)"
        case .null, .bool, .array, .object: nil
        }
    }

    private func encoded(_ message: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A JSONValue is made of JSON's own types, so encoding it can't fail.
        let data = (try? encoder.encode(message)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
