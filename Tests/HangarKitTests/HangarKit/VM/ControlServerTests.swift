import Darwin
import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@MainActor
private final class RequestLog {
    var requests: [ControlRequest] = []
}

struct ControlServerTests {
    private static func makeBundle() throws -> VMBundle {
        let directory = URL(fileURLWithPath: "/tmp/hangar-ctl-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return VMBundle(url: directory)
    }

    @concurrent
    private func send(_ request: ControlRequest, to bundle: VMBundle) async throws -> ControlReply {
        try ControlClient.send(request, to: bundle, timeout: 5)
    }

    @concurrent
    private func sendLine(_ line: String, to bundle: VMBundle) async throws -> ControlReply {
        let fd = try ControlClient.connect(to: bundle, timeout: 5)
        defer { close(fd) }

        try ControlSocket.writeAll(fd, line + "\n")
        let reply = try #require(ControlSocket.readLine(from: fd))
        return try ControlSocket.decodeMessage(ControlReply.self, from: reply)
    }

    @MainActor
    @Test func aMessageToAClosedConnectionFailsInsteadOfVanishing() throws {
        var ends: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        var noSigPipe: Int32 = 1
        setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        close(ends[1])
        defer { close(ends[0]) }

        let refusal = failureMessage { try ControlSocket.writeMessage(ControlRequest.status, to: ends[0]) }

        #expect(refusal == "Could not send a message to the VM: Broken pipe.")
    }

    @Test func requestsReachTheServerAndRepliesComeBack() async throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let server = try ControlServer(socketURL: bundle.controlSocketURL) { request in
            request == .status ? .state(.running) : .failed("'dev' is not paused.")
        }
        defer { server.invalidate() }

        var info = stat()
        #expect(stat(bundle.controlSocketURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(try await send(.status, to: bundle) == .state(.running))
        let error = await #expect(throws: HangarError.self) { try await self.send(.resume, to: bundle) }
        #expect(error?.message == "'dev' is not paused.")
    }

    @MainActor
    @Test func unreadableRequestsNeverReachTheHandler() async throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let log = RequestLog()
        let server = try ControlServer(socketURL: bundle.controlSocketURL) { request in
            log.requests.append(request)
            return .done
        }
        defer { server.invalidate() }
        let unreadable = [
            "garbage", "{}", #"{"status":{},"stop":{}}"#, #"{"status":{}} trailing"#, #"{"status":"now"}"#,
            #"{"status":{}}"# + String(repeating: " ", count: 5000),
        ]

        for line in unreadable {
            #expect(try await sendLine(line, to: bundle) == .failed("Hangar can't read that request."))
        }
        let readable = try await sendLine(#"{"status":{}}"#, to: bundle)

        #expect(readable == .done)
        #expect(log.requests == [.status])
    }

    @concurrent
    private func openExec(_ request: ExecRequest, to bundle: VMBundle) async throws -> Int32 {
        try ControlClient.openExec(request, to: bundle)
    }

    @Test func anExecConnectionIsHandedOverAndCarriesFrames() async throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let server = try ControlServer(
            socketURL: bundle.controlSocketURL,
            exec: { request, client in
                try? ControlSocket.writeMessage(ControlReply.done, to: client)
                try? ExecConnection(readFD: client, writeFD: client).send(.exit(code: Int32(request.command.count)))
                close(client)
            },
            handler: { _ in .failed("Exec requests go to the exec handler.") }
        )
        defer { server.invalidate() }
        let request = ExecRequest(command: ["uname", "-a"], tty: false, interactive: false, columns: 80, rows: 24)

        let fd = try await openExec(request, to: bundle)
        defer { close(fd) }

        #expect(try ExecConnection(readFD: fd, writeFD: fd).receive()?.exitCode == 2)
    }

    @Test func aRefusedExecSaysWhy() async throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let server = try ControlServer(
            socketURL: bundle.controlSocketURL,
            exec: { _, client in
                try? ControlSocket.writeMessage(ControlReply.failed("'dev' isn't running."), to: client)
                close(client)
            },
            handler: { _ in .done }
        )
        defer { server.invalidate() }
        let request = ExecRequest(command: ["true"], tty: false, interactive: false, columns: 80, rows: 24)

        let error = await #expect(throws: HangarError.self) { try await self.openExec(request, to: bundle) }

        #expect(error?.message == "'dev' isn't running.")
    }

    @MainActor
    @Test func failureMessagesStayOneReadableLine() async throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let multiline = "first\nsecond"
        let long = String(repeating: "\u{1}", count: 10_000)
        let server = try ControlServer(socketURL: bundle.controlSocketURL) { request in
            request == .stop ? .failed(multiline) : .failed(long)
        }
        defer { server.invalidate() }

        let multilineError = await #expect(throws: HangarError.self) { try await self.send(.stop, to: bundle) }
        let longError = await #expect(throws: HangarError.self) { try await self.send(.pause, to: bundle) }

        #expect(multilineError?.message == multiline)
        #expect(longError?.message == String(repeating: "\u{1}", count: 512))
    }
}
