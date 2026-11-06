import Compression
import Foundation
import HangarSupport

/// Turns a qcow2 cloud image, like Debian's and Ubuntu's, into the raw disk Virtualization starts.
package enum QCOW2 {
    static let maximumDiskSize: UInt64 = 64 * ByteSize.gib
    static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]
    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62
    private static let zeroFlag: UInt64 = 1
    private static let readableFeatures: UInt64 = 0b1001

    package static func isImage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)).map { [UInt8]($0) == magic } ?? false
    }

    package static func convert(_ image: URL, to disk: URL, progress: ProgressHandler) throws {
        let source = try Source(image)
        defer { source.close() }

        let header = try Header(reading: source)
        let l1 = try source.read(header.l1Offset, Int(header.l1Count * 8))
        try checkFreeSpace(for: header.size, next: disk, name: source.name)

        try SparseFile.create(at: disk, size: header.size, truncateExisting: true)
        let output = try FileHandle(forWritingTo: disk)
        defer { try? output.close() }
        try copyClusters(from: source, header: header, l1: l1, to: output, progress: progress)
    }

    private static func checkFreeSpace(for size: UInt64, next disk: URL, name: String) throws {
        let folder = disk.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        guard free <= 0 || UInt64(free) >= size else {
            throw HangarError("Not enough free space to convert \(name): it needs up to \(ByteSize.format(size)).")
        }
    }

    private static func copyClusters(
        from source: Source, header: Header, l1: [UInt8], to output: FileHandle, progress: ProgressHandler
    ) throws {
        var scratch = [UInt8](repeating: 0, count: Int(header.clusterSize))
        for tableIndex in 0..<header.tableCount {
            let tableOffset = bigEndian(l1, Int(tableIndex) * 8, 8) & offsetMask
            guard tableOffset != 0 else { continue }
            guard tableOffset % header.clusterSize == 0 else { throw source.damaged() }

            let table = try source.read(tableOffset, Int(header.clusterSize))
            let firstGuestOffset = tableIndex * header.entriesPerTable * header.clusterSize
            try copyTable(
                table, startingAt: firstGuestOffset, from: source, header: header, to: output, scratch: &scratch,
                progress: progress)
        }
    }

    private static func copyTable(
        _ table: [UInt8], startingAt firstGuestOffset: UInt64, from source: Source, header: Header,
        to output: FileHandle, scratch: inout [UInt8], progress: ProgressHandler
    ) throws {
        for entryIndex in 0..<header.entriesPerTable {
            try Task.checkCancellation()
            let guestOffset = firstGuestOffset + entryIndex * header.clusterSize
            guard guestOffset < header.size else { break }

            let length = Int(min(header.clusterSize, header.size - guestOffset))
            let entry = bigEndian(table, Int(entryIndex) * 8, 8)
            guard let data = try clusterData(entry, length: length, from: source, header: header, scratch: &scratch)
            else { continue }
            if data.contains(where: { $0 != 0 }) {
                try output.seek(toOffset: guestOffset)
                try output.write(contentsOf: data)
            }

            guard entryIndex % 64 == 0 else { continue }
            reportProgress(done: guestOffset + UInt64(length), of: header.size, to: progress)
        }
    }

    private static func clusterData(
        _ entry: UInt64, length: Int, from source: Source, header: Header, scratch: inout [UInt8]
    ) throws -> [UInt8]? {
        if entry & compressedFlag != 0 {
            return try compressedClusterData(entry, length: length, from: source, header: header, scratch: &scratch)
        }

        let hostOffset = entry & offsetMask
        guard entry & zeroFlag == 0, hostOffset != 0 else { return nil }
        guard hostOffset % header.clusterSize == 0 else { throw source.damaged() }
        return try source.read(hostOffset, length)
    }

    private static func compressedClusterData(
        _ entry: UInt64, length: Int, from source: Source, header: Header, scratch: inout [UInt8]
    ) throws -> [UInt8] {
        let hostOffset = entry & ((UInt64(1) << header.compressedShift) - 1)
        let sectors = ((entry >> header.compressedShift) & ((UInt64(1) << header.compressedBits) - 1)) + 1
        let available = source.size > hostOffset ? source.size - hostOffset : 0
        let compressed = try source.read(hostOffset, Int(min(sectors * 512 - (hostOffset & 511), available)))

        let decoded = scratch.withUnsafeMutableBytes { target in
            compressed.withUnsafeBytes { CompressedData.decode($0, into: target, using: COMPRESSION_ZLIB) }
        }
        guard decoded >= length else { throw source.damaged() }
        return Array(scratch[0..<length])
    }

    private static func reportProgress(done: UInt64, of size: UInt64, to progress: ProgressHandler) {
        progress(
            CreationProgress(
                phase: "Converting the disk image",
                fraction: Double(done) / Double(size),
                detail: "\(ByteSize.format(done)) of \(ByteSize.format(size))"))
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
        bytes[offset..<(offset + width)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private final class Source {
        let name: String
        let size: UInt64
        private let handle: FileHandle

        init(_ url: URL) throws {
            name = url.lastPathComponent
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
        }

        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
            guard !overflow, end <= size else { throw damaged() }
            try handle.seek(toOffset: offset)
            let data = [UInt8](try handle.readPiece(upToCount: count) ?? Data())
            guard data.count == count else { throw damaged() }
            return data
        }

        func damaged() -> HangarError {
            HangarError("\(name) is not a qcow2 image Hangar can read.")
        }

        func close() {
            try? handle.close()
        }
    }

    private struct Header {
        /// The header's fields, by byte offset; version 2 ends at 72, version 3 at 104, and the compression type
        /// byte, when present, follows.
        private enum Field {
            static let version = 4
            static let backingFileOffset = 8
            static let clusterBits = 20
            static let size = 24
            static let cryptMethod = 32
            static let l1Count = 36
            static let l1Offset = 40
            static let incompatibleFeatures = 72
            static let compressionType = 104
        }

        private static let version2Length = 72
        private static let version3Length = 104
        private static let longestHeader = 112
        /// 512 B to 2 MiB clusters, as the QCOW2 format allows.
        private static let clusterBitsRange: ClosedRange<UInt64> = 9...21
        private static let largestL1Count: UInt64 = 1 << 22
        private static let compressionTypeFeature: UInt64 = 0b1000

        let size: UInt64
        let clusterBits: UInt64
        let l1Count: UInt64
        let l1Offset: UInt64

        var clusterSize: UInt64 { UInt64(1) << clusterBits }
        var entriesPerTable: UInt64 { clusterSize / 8 }
        var tableCount: UInt64 { (size + clusterSize * entriesPerTable - 1) / (clusterSize * entriesPerTable) }
        var compressedBits: UInt64 { clusterBits - 8 }
        var compressedShift: UInt64 { 62 - compressedBits }

        init(reading source: Source) throws {
            let bytes = try source.read(0, min(Self.longestHeader, Int(source.size)))
            guard bytes.count >= Self.version2Length, bytes.starts(with: magic) else { throw source.damaged() }

            let version = bigEndian(bytes, Field.version, 4)
            try Self.checkVersion(bytes, version: version, name: source.name)
            clusterBits = bigEndian(bytes, Field.clusterBits, 4)
            size = bigEndian(bytes, Field.size, 8)
            guard Self.clusterBitsRange.contains(clusterBits) else { throw source.damaged() }
            guard size <= maximumDiskSize else {
                throw HangarError("\(source.name) is larger than \(ByteSize.format(maximumDiskSize)).")
            }
            try Self.checkFeatures(bytes, version: version, name: source.name, damaged: source.damaged())

            l1Count = bigEndian(bytes, Field.l1Count, 4)
            l1Offset = bigEndian(bytes, Field.l1Offset, 8)
            guard l1Count >= tableCount, l1Count <= Self.largestL1Count else { throw source.damaged() }
        }

        private static func checkVersion(_ bytes: [UInt8], version: UInt64, name: String) throws {
            guard version == 2 || version == 3 else {
                throw HangarError("\(name) uses qcow2 version \(version), which Hangar can't read.")
            }
            guard bigEndian(bytes, Field.backingFileOffset, 8) == 0 else {
                throw HangarError("\(name) needs a backing file; use a standalone image.")
            }
        }

        private static func checkFeatures(_ bytes: [UInt8], version: UInt64, name: String, damaged: HangarError) throws
        {
            guard bigEndian(bytes, Field.cryptMethod, 4) == 0 else { throw HangarError("\(name) is encrypted.") }
            guard version == 3 else { return }

            guard bytes.count >= version3Length else { throw damaged }
            let features = bigEndian(bytes, Field.incompatibleFeatures, 8)
            guard features & ~readableFeatures == 0 else {
                throw HangarError("\(name) uses qcow2 features Hangar can't read.")
            }

            let usesCompressionType = features & compressionTypeFeature != 0
            let isZlib = bytes.count > Field.compressionType && bytes[Field.compressionType] == 0
            guard !usesCompressionType || isZlib else {
                throw HangarError("\(name) uses zstd compression, which Hangar can't read.")
            }
        }
    }
}
