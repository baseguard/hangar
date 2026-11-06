import Darwin
import Foundation

/// Moves a file or folder to a name nobody has. The volume decides whether a name is taken, so a name that differs
/// only in case or Unicode form counts as taken where the volume says so.
package enum FileMove {
    package typealias ExclusiveRename = (_ from: String, _ to: String) -> Int32

    /// False when something is at `target` already; `item` then stays where it is.
    package static func withoutReplacing(
        _ item: URL, to target: URL,
        exclusiveRename: ExclusiveRename = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    ) throws -> Bool {
        if exclusiveRename(item.path, target.path) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        // exFAT has no exclusive rename.
        guard code == ENOTSUP else { throw HangarError(errno: code, "Could not save \(target.path)") }
        return try claimThenRename(item, to: target)
    }

    /// Takes the name with an exclusive create of the same kind, then renames over that empty claim, which is ours.
    private static func claimThenRename(_ item: URL, to target: URL) throws -> Bool {
        guard try claim(target, sameKindAs: item) else { return false }
        guard rename(item.path, target.path) == 0 else {
            let code = errno
            remove(target.path)
            throw HangarError(errno: code, "Could not save \(target.path)")
        }
        return true
    }

    /// An empty folder for a folder, an empty file for anything else; false when the name is taken.
    private static func claim(_ target: URL, sameKindAs item: URL) throws -> Bool {
        if try isFolder(item) {
            if mkdir(target.path, 0o700) == 0 { return true }
        } else {
            let file = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file >= 0 {
                close(file)
                return true
            }
        }
        let code = errno
        if code == EEXIST { return false }
        throw HangarError(errno: code, "Could not save \(target.path)")
    }

    private static func isFolder(_ item: URL) throws -> Bool {
        var info = stat()
        guard lstat(item.path, &info) == 0 else { throw HangarError(errno: errno, "Could not read \(item.path)") }
        return info.st_mode & S_IFMT == S_IFDIR
    }
}
