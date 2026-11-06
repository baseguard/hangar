import Darwin
import Foundation
import HangarSupport
import System

final class GuestDirectory {
    let descriptor: Int32

    init(path: String) throws {
        descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HangarError(errno: errno, "Could not open \(path)") }
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func child(_ name: String) throws -> GuestDirectory {
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            throw HangarError(errno: errno, "Could not open \(name) in the image")
        }
        return GuestDirectory(descriptor: child)
    }

    func directory(_ path: [String], creating: Bool = false) throws -> GuestDirectory {
        var current = GuestDirectory(descriptor: dup(descriptor))
        for name in path {
            if creating, mkdirat(current.descriptor, name, 0o755) != 0, errno != EEXIST {
                throw HangarError(errno: errno, "Could not create \(name) in the image")
            }
            current = try current.child(name)
        }
        return current
    }

    /// A missing folder on the way means no; a link or file in a folder's place throws, because a tool that
    /// follows the path would go through it.
    func exists(_ path: [String]) throws -> Bool {
        guard let name = path.last else { return true }
        var current = GuestDirectory(descriptor: dup(descriptor))
        for folder in path.dropLast() {
            guard current.contains(folder) else { return false }
            current = try current.child(folder)
        }
        return current.contains(name)
    }

    private func contains(_ name: String) -> Bool {
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    func write(_ data: Data, at path: [String], mode: mode_t) throws {
        guard let name = path.last else { return }

        let parent = try directory(Array(path.dropLast()), creating: true)
        var info = stat()

        if fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw HangarError("\(path.joined(separator: "/")) in the image is not a regular file.")
        }

        let file = openat(parent.descriptor, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else {
            throw HangarError(errno: errno, "Could not write \(path.joined(separator: "/")) in the image")
        }
        defer { close(file) }
        guard (try? FileDescriptor(rawValue: file).writeAll(data)) != nil else {
            throw HangarError("Could not write \(name) in the image.")
        }
        guard fchown(file, 0, 0) == 0, fchmod(file, mode) == 0 else {
            throw HangarError(errno: errno, "Could not give \(name) in the image to root")
        }
    }
}
