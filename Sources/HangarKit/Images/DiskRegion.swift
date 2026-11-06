import Darwin
import Foundation
import HangarSupport
import System

enum DiskRegion {
    static let blockSize = 4096

    static let pieceSize = 1 << 20
    private static let zeros = [UInt8](repeating: 0, count: pieceSize)

    /// Writes a region piece by piece through one open file, so a 256 MiB part never sits in memory whole. The
    /// region is cleared first and only non-zero runs are written, so the disk stays sparse; it is saved once.
    static func write(
        to disk: URL, at offset: UInt64, length: UInt64, pieces: (_ write: (Data) throws -> Void) throws -> Void
    ) throws {
        let fd = open(disk.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(disk.lastPathComponent)") }
        defer { close(fd) }

        try clear(fd, from: offset, length: length)
        var position = offset
        try pieces { piece in
            guard position + UInt64(piece.count) <= offset + length else {
                throw HangarError("A disk part ran past its region.")
            }
            try piece.withUnsafeBytes { try writeNonZeroRuns(of: $0, to: fd, at: position) }
            position += UInt64(piece.count)
        }
        guard fsync(fd) == 0 else { throw HangarError(errno: errno, "Could not save the disk") }
    }

    static func read(
        _ disk: URL, at offset: UInt64, length: UInt64, pieces: (Data) throws -> Void
    ) throws {
        let fd = open(disk.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(disk.lastPathComponent)") }
        defer { close(fd) }

        for start in stride(from: offset, to: offset + length, by: pieceSize) {
            var piece = Data(count: Int(min(UInt64(pieceSize), offset + length - start)))
            let count = piece.count
            let done = try piece.withUnsafeMutableBytes { buffer in
                do {
                    return try FileDescriptor(rawValue: fd).readFully(into: buffer, at: Int64(start))
                } catch let error as Errno {
                    throw HangarError(errno: error.rawValue, "Could not read \(disk.lastPathComponent)")
                }
            }
            guard done == count else { throw HangarError("\(disk.lastPathComponent) ended before Hangar read it all.") }
            try pieces(piece)
        }
    }

    /// Copies a region to another place in the same disk, for parts an image holds more than once.
    static func copy(in disk: URL, from source: UInt64, to target: UInt64, length: UInt64) throws {
        try write(to: disk, at: target, length: length) { write in
            try read(disk, at: source, length: length, pieces: write)
        }
    }

    /// False for a region the file system keeps as a hole, which needs no reading at all.
    static func hasData(_ disk: URL, at offset: UInt64, length: UInt64) throws -> Bool {
        let fd = open(disk.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(disk.lastPathComponent)") }
        defer { close(fd) }
        let firstData = lseek(fd, off_t(offset), SEEK_DATA)
        guard firstData >= 0 else {
            guard errno == ENXIO else { throw HangarError(errno: errno, "Could not read \(disk.lastPathComponent)") }
            return false
        }
        return UInt64(firstData) < offset + length
    }

    private static func writeNonZeroRuns(of buffer: UnsafeRawBufferPointer, to fd: Int32, at offset: UInt64) throws {
        guard let bytes = buffer.baseAddress else { return }
        var runStart: Int?
        var index = 0
        while index < buffer.count {
            let length = min(blockSize, buffer.count - index)
            let empty = isZero(bytes + index, count: length)
            if empty, let first = runStart {
                try writeAll(
                    fd, UnsafeRawBufferPointer(start: bytes + first, count: index - first), at: offset + UInt64(first))
                runStart = nil
            } else if !empty, runStart == nil {
                runStart = index
            }
            index += length
        }

        if let first = runStart {
            try writeAll(fd, UnsafeRawBufferPointer(rebasing: buffer[first...]), at: offset + UInt64(first))
        }
    }

    private static func clear(_ fd: Int32, from offset: UInt64, length: UInt64) throws {
        let block = UInt64(blockSize)
        let end = offset + length
        let holeStart = min((offset + block - 1) / block * block, end)
        let holeEnd = max(end / block * block, holeStart)

        if holeEnd > holeStart {
            var hole = fpunchhole_t(
                fp_flags: 0, reserved: 0, fp_offset: off_t(holeStart), fp_length: off_t(holeEnd - holeStart))
            if fcntl(fd, F_PUNCHHOLE, &hole) != 0 {
                try writeZeros(fd, from: holeStart, to: holeEnd)
            }
        }

        try writeZeros(fd, from: offset, to: holeStart)
        try writeZeros(fd, from: holeEnd, to: end)
    }

    private static func writeZeros(_ fd: Int32, from lower: UInt64, to upper: UInt64) throws {
        var offset = lower
        while offset < upper {
            let count = Int(min(upper - offset, UInt64(zeros.count)))
            try zeros.withUnsafeBytes { try writeAll(fd, UnsafeRawBufferPointer(rebasing: $0[..<count]), at: offset) }
            offset += UInt64(count)
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at offset: UInt64) throws {
        do {
            _ = try FileDescriptor(rawValue: fd).writeAll(toAbsoluteOffset: Int64(offset), bytes)
        } catch let error as Errno {
            throw HangarError(errno: error.rawValue, "Could not write the disk")
        }
    }

    static func isZero(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return true }
            return isZero(start, count: buffer.count)
        }
    }

    static func isZero(_ bytes: UnsafeRawPointer, count: Int) -> Bool {
        var index = 0
        while index + 8 <= count {
            if bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) != 0 { return false }
            index += 8
        }
        while index < count {
            if bytes.load(fromByteOffset: index, as: UInt8.self) != 0 { return false }
            index += 1
        }
        return true
    }
}
