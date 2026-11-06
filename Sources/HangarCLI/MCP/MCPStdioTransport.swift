import Foundation
import HangarSupport
import Logging
import MCP

/// MCP over stdin and stdout, one JSON message per line. The SDK's own stdio transport polls stdin every 10 ms and
/// keeps lines of any length; this one waits on stdin, skips a line over `MCPLineSplitter.maximumLength` so one
/// endless line can't fill this Mac's memory, and when stdin ends it still answers the requests that came before.
actor MCPStdioTransport: Transport {
    /// Enough of a message to tell, the way the SDK does, a request that waits for an answer from an answer.
    private struct Envelope: Decodable {
        var jsonrpc: String?
        var id: ID?
        var method: String?
        var result: Value?
        var error: Value?

        var isRequest: Bool {
            jsonrpc == "2.0" && id != nil && method != nil && result == nil && error == nil
        }
    }

    private struct Cancellation: Decodable {
        struct Params: Decodable {
            var requestId: ID
        }

        var params: Params
    }

    nonisolated let logger = Logger(label: "io.baseguard.hangar.mcp") { _ in SwiftLogNoOpLogHandler() }
    private nonisolated let messages: AsyncThrowingStream<Data, any Error>
    private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
    /// The client's requests that have no answer yet.
    private var unanswered: Set<ID> = []
    private var hasInputEnded = false

    init() {
        (messages, incoming) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        Task { await readInput() }
    }

    func disconnect() async {
        incoming.finish()
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }

    /// An answer that can't be written still counts as given: a client that closed stdout reads no more, and the
    /// server must still end.
    func send(_ data: Data) async throws {
        if let answer = try? JSONDecoder().decode(Envelope.self, from: data), let id = answer.id, answer.method == nil {
            unanswered.remove(id)
        }
        defer { finishIfAnswered() }
        try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    }

    @concurrent
    private nonisolated func readInput() async {
        var lines = MCPLineSplitter()
        do {
            for try await byte in FileHandle.standardInput.bytes {
                guard let line = lines.add(byte) else { continue }
                await take(line)
            }
        } catch {
            // A read error ends the input the way its end does.
        }
        if let last = lines.finish() { await take(last) }
        await endInput()
    }

    private func take(_ line: MCPLine) {
        switch line {
        case .message(let text):
            let data = Data(text.utf8)
            noteRequest(in: data)
            incoming.yield(data)
        case .tooLong:
            let limit = ByteSize.format(UInt64(MCPLineSplitter.maximumLength))
            FileHandle.standardError.write(Data("hangar mcp: skipped a message over \(limit).\n".utf8))
        }
    }

    /// A request waits for its answer; a cancelled one gets none, so it waits no longer.
    private func noteRequest(in data: Data) {
        guard let message = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        if message.isRequest, let id = message.id {
            unanswered.insert(id)
        } else if message.method == "notifications/cancelled", message.id == nil,
            let cancellation = try? JSONDecoder().decode(Cancellation.self, from: data)
        {
            unanswered.remove(cancellation.params.requestId)
        }
    }

    private func endInput() {
        hasInputEnded = true
        finishIfAnswered()
    }

    /// Ending the messages ends the server, so that waits until every request before the end has its answer.
    private func finishIfAnswered() {
        guard hasInputEnded, unanswered.isEmpty else { return }
        incoming.finish()
    }
}
