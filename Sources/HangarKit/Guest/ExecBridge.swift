import Darwin
import Foundation

/// Joins a `hangar exec` caller to its connection to the guest agent: the VM's process sends the start frame, then
/// passes bytes both ways without reading them, until either side is done.
package enum ExecBridge {
    /// The guest agent's vsock port for `hangar exec` (`hangar_exec_frames::VSOCK_PORT`).
    package static let port: UInt32 = 700
    private static let chunkSize = 64 * 1024

    /// Takes both descriptors and closes them once both directions ended. A caller that leaves ends the connection to
    /// the guest, which ends the command there. Each direction gets a thread of its own, since it waits in `read` for as
    /// long as the command runs, which would hold up Dispatch's shared threads.
    package static func relay(caller: Int32, guest: Int32, start: Data) {
        for fd in [caller, guest] {
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
        let copies = DispatchGroup()
        copies.enter()
        copies.enter()
        Thread.detachNewThread {
            if writeAll(start, to: guest) {
                copy(from: caller, to: guest)
            }
            shutDown(caller, guest)
            copies.leave()
        }
        Thread.detachNewThread {
            copy(from: guest, to: caller)
            shutDown(caller, guest)
            copies.leave()
        }
        copies.notify(queue: .global()) {
            close(caller)
            close(guest)
        }
    }

    /// Until `from` ends or either side fails.
    static func copy(from: Int32, to: Int32) {
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, writeAll(Data(chunk[0..<count]), to: to) else { return }
        }
    }

    private static func writeAll(_ bytes: Data, to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Wakes the other copy, which may be waiting to read.
    private static func shutDown(_ caller: Int32, _ guest: Int32) {
        shutdown(caller, SHUT_RDWR)
        shutdown(guest, SHUT_RDWR)
    }
}
