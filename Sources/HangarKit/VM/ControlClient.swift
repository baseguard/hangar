import Darwin
import Foundation
import HangarSupport

package struct NoAnswer: LocalizedError {
    package let name: String
    package var errorDescription: String? { "'\(name)' did not answer." }
}

package enum ControlClient {
    /// The finer state of a VM that holds its run lock. One that doesn't answer in time, or is too early in
    /// starting to have its socket, is still running; only an answer that makes no sense is unknown.
    package static func runningState(of bundle: VMBundle) -> MachineState {
        guard FileManager.default.fileExists(atPath: bundle.controlSocketURL.path) else { return .running }
        do {
            return try send(.status, to: bundle, timeout: 1).machineState ?? .unknown
        } catch is NoAnswer {
            return .running
        } catch {
            return .unknown
        }
    }

    package static func send(_ request: ControlRequest, to bundle: VMBundle, timeout: Int = 30) throws -> ControlReply {
        let fd = try connect(to: bundle, timeout: timeout)
        defer { close(fd) }

        try ControlSocket.writeMessage(request, to: fd)
        let line = ControlSocket.readLine(from: fd)
        if line?.isEmpty == true { throw NoAnswer(name: bundle.name) }
        return try reply(from: line, of: bundle)
    }

    /// For a request that can take minutes, like a snapshot of a running VM: the wait blocks a dispatch thread, never
    /// one of the few threads Swift concurrency runs every task on.
    package static func sendWaiting(_ request: ControlRequest, to bundle: VMBundle, timeout: Int) async throws
        -> ControlReply
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try send(request, to: bundle, timeout: timeout) })
            }
        }
    }

    /// Sends a `hangar exec` request and returns the connection once the VM took it; the caller then speaks exec frames
    /// on it and closes it.
    package static func openExec(_ request: ExecRequest, to bundle: VMBundle) throws -> Int32 {
        let message = ControlRequest.exec(request)
        guard try JSONEncoder().encode(message).count < ControlSocket.maximumLineBytes else {
            throw HangarError("The command is too long for hangar exec; put it in a script and run that.")
        }

        let fd = try connect(to: bundle, timeout: 30)
        do {
            try ControlSocket.writeMessage(message, to: fd)
            let line = ControlSocket.readLine(from: fd)
            if line?.isEmpty == true { throw NoAnswer(name: bundle.name) }
            _ = try reply(from: line, of: bundle)
        } catch {
            close(fd)
            throw error
        }

        // The command can stay quiet for as long as it likes.
        var noTimeout = timeval()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func connect(to bundle: VMBundle, timeout: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open a socket for '\(bundle.name)'") }
        var address = try ControlSocket.unixAddress(bundle.controlSocketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = HangarError(errno: errno, "Could not reach '\(bundle.name)'")
            close(fd)
            throw failure
        }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func reply(from line: String?, of bundle: VMBundle) throws -> ControlReply {
        guard let line, let reply = try? ControlSocket.decodeMessage(ControlReply.self, from: line) else {
            throw HangarError("'\(bundle.name)' sent an answer Hangar can't read.")
        }
        if case .failed(let message) = reply { throw HangarError(message) }
        return reply
    }
}
