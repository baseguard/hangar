import Darwin
import Foundation
import HangarSupport
import Synchronization

/// Frames over `hangar exec`'s control socket, which the VM's process joins to a connection to the guest agent. Sends from
/// any thread are serialized; receiving is for one thread at a time. It doesn't close the descriptors.
package final class ExecConnection: Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let writeLock = Mutex(())
    private let reader = Mutex(ExecFrameReader())
    private let chunk = Mutex([UInt8](repeating: 0, count: ExecFrame.maximumPayload))

    /// The other side took nothing, or sent nothing, for as long as the socket's time limit allows.
    struct StoppedAnswering: LocalizedError {
        var errorDescription: String? { "The guest stopped answering." }
    }

    package init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
        // A socket whose other side is gone, such as a stopped VM's, then fails the write instead of ending the process.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    }

    /// Blocks while the other side isn't reading.
    package func send(_ frame: ExecFrame) throws {
        try writeLock.withLock { _ in
            try writeAll(frame.encoded)
        }
    }

    private func writeAll(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(writeFD, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                // SO_SNDTIMEO ran out; EWOULDBLOCK is EAGAIN on Darwin.
                if written < 0, errno == EAGAIN { throw StoppedAnswering() }
                guard written > 0 else { throw HangarError(errno: errno, "Could not send to the command") }
                offset += written
            }
        }
    }

    /// The next whole frame; nil once the other side closed or the read failed. Throws StoppedAnswering when the
    /// socket's receive time limit ran out, which isn't the end of the command's output.
    package func receive() throws -> ExecFrame? {
        while true {
            if let frame = try reader.withLock({ try $0.nextFrame() }) { return frame }
            guard try readMore() else { return nil }
        }
    }

    /// False once the other side closed or the read failed.
    private func readMore() throws -> Bool {
        try chunk.withLock { chunk in
            while true {
                let count = chunk.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                // SO_RCVTIMEO ran out; EWOULDBLOCK is EAGAIN on Darwin.
                if count < 0, errno == EAGAIN { throw StoppedAnswering() }
                guard count > 0 else { return false }
                reader.withLock { $0.feed(chunk[0..<count]) }
                return true
            }
        }
    }
}
