import Darwin
import Foundation
import HangarSupport

package enum SparseFile {
    package static func create(at url: URL, size: UInt64, truncateExisting: Bool = false) throws {
        guard size <= UInt64(Int64.max) else { throw HangarError("\(ByteSize.format(size)) is too large for a disk.") }
        let flags = O_RDWR | O_CREAT | (truncateExisting ? O_TRUNC : O_EXCL)
        let fd = open(url.path, flags, 0o600)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not create \(url.path)") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw HangarError(errno: errno, "Could not size \(url.path)")
        }
    }
}
