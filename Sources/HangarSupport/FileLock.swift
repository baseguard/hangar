import Darwin
import Foundation

package final class FileLock {
    package enum Mode {
        case shared
        case exclusive

        var flag: Int32 { self == .shared ? LOCK_SH : LOCK_EX }
    }

    package let url: URL
    private var fd: Int32 = -1

    package init(url: URL) {
        self.url = url
    }

    deinit {
        unlock()
    }

    package func tryLock(_ mode: Mode) throws -> Bool {
        try open()
        if flock(fd, mode.flag | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw HangarError(errno: errno, "Could not lock \(url.path)")
    }

    package func tryLock(_ mode: Mode, retryingFor timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try tryLock(mode) { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    package func lock(_ mode: Mode) throws {
        try open()
        while flock(fd, mode.flag) != 0 {
            if errno != EINTR {
                throw HangarError(errno: errno, "Could not lock \(url.path)")
            }
        }
    }

    package func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    package func write(_ data: Data) throws {
        guard fd >= 0 else { throw HangarError("\(url.path) is not locked, so it can't be written.") }
        guard ftruncate(fd, 0) == 0 else {
            throw HangarError(errno: errno, "Could not write \(url.path)")
        }
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count else {
            if written < 0 { throw HangarError(errno: errno, "Could not write \(url.path)") }
            throw HangarError("Only part of \(url.path) was written.")
        }
    }

    /// False once the lock file was deleted or replaced while this lock waited, so holding it guards nothing.
    package var isStillAtItsPath: Bool {
        var held = stat()
        var current = stat()
        guard fd >= 0, fstat(fd, &held) == 0, stat(url.path, &current) == 0 else { return false }
        return held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }

    package static func isHeld(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func open() throws {
        guard fd < 0 else { return }
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw HangarError(errno: errno, "Could not open \(url.path)")
        }
    }
}
