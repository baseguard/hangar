import Darwin
import Foundation
import HangarSupport

final class ControlServer {
    /// Few clients connect at once; a request that stays silent this long is dropped.
    private static let backlog: Int32 = 8
    private static let requestTimeout = 5

    private let path: String
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "io.baseguard.hangar.control")

    /// `exec` gets each `hangar exec` connection with its request and closes it; `handler` answers every other request.
    init(
        socketURL: URL, exec: @escaping @Sendable (ExecRequest, Int32) -> Void = { _, client in close(client) },
        handler: @escaping @MainActor (ControlRequest) async -> ControlReply
    ) throws {
        path = socketURL.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open a socket for \(path)") }
        do {
            var address = try ControlSocket.unixAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, Self.backlog) == 0 else {
                throw HangarError(errno: errno, "Could not listen on \(path)")
            }
        } catch {
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while case let client = accept(fd, nil, nil), client >= 0 {
                DispatchQueue.global(qos: .userInitiated).async { Self.serve(client, exec: exec, handler: handler) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func invalidate() {
        source.cancel()
        unlink(path)
    }

    private static func serve(
        _ client: Int32, exec: @escaping @Sendable (ExecRequest, Int32) -> Void,
        handler: @escaping @MainActor (ControlRequest) async -> ControlReply
    ) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            close(client)
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: Self.requestTimeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard let line = ControlSocket.readLine(from: client),
            let request = try? ControlSocket.decodeMessage(ControlRequest.self, from: line)
        else {
            try? ControlSocket.writeMessage(ControlReply.failed("Hangar can't read that request."), to: client)
            close(client)
            return
        }
        if case .exec(let execRequest) = request {
            // A command can stay quiet for as long as it likes.
            var noTimeout = timeval()
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            return exec(execRequest, client)
        }
        Task { @MainActor in
            let reply = await handler(request)
            try? ControlSocket.writeMessage(shortened(reply), to: client)
            close(client)
        }
    }

    // JSON escapes a byte into at most six, so this keeps a failure reply within one readable line.
    private static let maximumMessageBytes = ControlSocket.maximumLineBytes / 8

    private static func shortened(_ reply: ControlReply) -> ControlReply {
        guard case .failed(let message) = reply, message.utf8.count > maximumMessageBytes else { return reply }
        return .failed(String(decoding: message.utf8.prefix(maximumMessageBytes), as: UTF8.self))
    }
}
