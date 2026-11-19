import Foundation
import HangarSupport

/// A disk's GUID partition table (UEFI 2.10, chapter 5): a protective MBR in sector 0, the primary header in sector 1
/// with its entry array after it, and a backup header in the last sector with its own copy of the array before it.
/// Both headers and the array carry a CRC32, so every change is written to both copies with new checksums.
///
/// The table comes from a guest or a downloaded image, so every number in it is checked against the disk before it is
/// used: a table that points outside the disk, overflows or overlaps is damaged, not a reason to crash.
struct GUIDPartitionTable {
    struct Partition: Equatable {
        /// The entry's place in the array; diskutil names the partition `s<index + 1>`.
        let index: Int
        let type: UUID
        var firstSector: UInt64
        /// Inclusive, as the table stores it; never before `firstSector`.
        var lastSector: UInt64

        var sectorCount: UInt64 { lastSector - firstSector + 1 }
    }

    /// The header's fields, by byte offset.
    private enum Field {
        static let headerSize = 12
        static let headerChecksum = 16
        static let currentSector = 24
        static let backupSector = 32
        static let firstUsableSector = 40
        static let lastUsableSector = 48
        static let entriesSector = 72
        static let entryCount = 80
        static let entrySize = 84
        static let entriesChecksum = 88
    }

    /// An entry's fields, by byte offset.
    private enum EntryField {
        static let type = 0..<16
        static let firstSector = 32
        static let lastSector = 40
    }

    private static let signature = Array("EFI PART".utf8)
    private static let sectorSizes: [UInt64] = [512, 4096]
    private static let shortestHeader = 92
    private static let shortestEntry = 128
    /// Far more than the 128 entries of 128 bytes every table has; it bounds what a damaged header makes us read.
    private static let largestEntryArray = 1 << 20
    private static let mbrSize = 512
    private static let protectivePartition = 446
    private static let protectiveType: UInt8 = 0xEE

    let sectorSize: UInt64
    /// The primary header, as long as the header says it is.
    private var header: [UInt8]
    private var entries: [UInt8]
    private let entrySize: Int

    /// Partitions in use, in the order they lie on the disk.
    private(set) var partitions: [Partition]

    /// `nil` for a disk without a GPT; a damaged table is an error, since writing it back would make it look sound.
    static func read(from disk: FileHandle, diskSize: UInt64) throws -> GUIDPartitionTable? {
        for sectorSize in sectorSizes where sectorSize * 2 <= diskSize {
            let header = try read(disk, at: sectorSize, count: Int(sectorSize))
            guard header.starts(with: signature) else { continue }
            return try GUIDPartitionTable(disk: disk, diskSize: diskSize, sectorSize: sectorSize, headerSector: header)
        }
        return nil
    }

    private init(disk: FileHandle, diskSize: UInt64, sectorSize: UInt64, headerSector: [UInt8]) throws {
        let header = try Self.checkedHeader(headerSector)
        let entrySize = Int(Self.uint32(header, at: Field.entrySize))
        let arraySize = try Self.entryArraySize(of: header)
        let arrayOffset = try Self.byteOffset(
            ofSector: Self.uint64(header, at: Field.entriesSector), sectorSize: sectorSize, holding: UInt64(arraySize),
            onDiskOf: diskSize)
        let entries = try Self.read(disk, at: arrayOffset, count: arraySize)
        guard Self.uint32(header, at: Field.entriesChecksum) == CRC32.checksum(entries) else {
            throw Self.damaged("its entry checksum doesn't match")
        }

        let usable = try Self.usableSectors(in: header, diskSectors: diskSize / sectorSize)
        self.sectorSize = sectorSize
        self.header = header
        self.entries = entries
        self.entrySize = entrySize
        partitions = try Self.checkedPartitions(in: entries, entrySize: entrySize, within: usable)
    }

    private var entryArraySectors: UInt64 {
        (UInt64(entries.count) + sectorSize - 1) / sectorSize
    }

    /// The last usable sector of the same table on a disk of `size` bytes; `nil` for a disk too small to hold it.
    func lastUsableSector(onDiskOf size: UInt64) -> UInt64? {
        let sectors = size / sectorSize
        let reserved = entryArraySectors + 2
        return sectors > reserved ? sectors - reserved : nil
    }

    /// `first` must leave the partition within the usable sectors of the disk the table is written for.
    mutating func move(_ partition: Partition, toFirstSector first: UInt64) {
        let offset = partition.index * entrySize
        Self.setUInt64(&entries, at: offset + EntryField.firstSector, first)
        Self.setUInt64(&entries, at: offset + EntryField.lastSector, first + partition.sectorCount - 1)
        partitions = Self.partitionsInUse(entries, entrySize: entrySize)
    }

    /// Writes both headers, both entry arrays and the protective MBR for a disk now `size` bytes long, with the
    /// backup copies in its last sectors.
    func write(to disk: FileHandle, diskSize size: UInt64) throws {
        guard let lastUsable = lastUsableSector(onDiskOf: size) else {
            throw HangarError("The disk is too small for its partition table.")
        }
        let lastSector = size / sectorSize - 1
        let backupArraySector = lastSector - entryArraySectors
        let primaryArraySector = Self.uint64(header, at: Field.entriesSector)
        let primary = headerCopy(current: 1, backup: lastSector, entriesAt: primaryArraySector, lastUsable: lastUsable)
        let backup = headerCopy(current: lastSector, backup: 1, entriesAt: backupArraySector, lastUsable: lastUsable)

        try Self.write(disk, entries, at: primaryArraySector * sectorSize)
        try Self.write(disk, primary, at: sectorSize)
        try Self.write(disk, entries, at: backupArraySector * sectorSize)
        try Self.write(disk, backup, at: lastSector * sectorSize)
        try updateProtectiveMBR(of: disk, sectorCount: lastSector + 1)
    }

    /// The header for one of the two places it is stored.
    private func headerCopy(current: UInt64, backup: UInt64, entriesAt entrySector: UInt64, lastUsable: UInt64)
        -> [UInt8]
    {
        var copy = header
        Self.setUInt64(&copy, at: Field.currentSector, current)
        Self.setUInt64(&copy, at: Field.backupSector, backup)
        Self.setUInt64(&copy, at: Field.lastUsableSector, lastUsable)
        Self.setUInt64(&copy, at: Field.entriesSector, entrySector)
        Self.setUInt32(&copy, at: Field.entriesChecksum, CRC32.checksum(entries))
        Self.setUInt32(&copy, at: Field.headerChecksum, Self.headerChecksum(copy))
        return copy
    }

    /// The protective partition covers the whole disk, up to the most 32 bits can say.
    private func updateProtectiveMBR(of disk: FileHandle, sectorCount: UInt64) throws {
        var mbr = try Self.read(disk, at: 0, count: Self.mbrSize)
        guard mbr[Self.protectivePartition + 4] == Self.protectiveType else { return }
        let protectedSectors = UInt32(min(sectorCount - 1, UInt64(UInt32.max)))
        Self.setUInt32(&mbr, at: Self.protectivePartition + 12, protectedSectors)
        try Self.write(disk, mbr, at: 0)
    }

    private static func checkedHeader(_ headerSector: [UInt8]) throws -> [UInt8] {
        let headerSize = Int(uint32(headerSector, at: Field.headerSize))
        guard (shortestHeader...headerSector.count).contains(headerSize) else {
            throw damaged("its header size is wrong")
        }
        let header = Array(headerSector.prefix(headerSize))
        guard uint32(header, at: Field.headerChecksum) == headerChecksum(header) else {
            throw damaged("its header checksum doesn't match")
        }
        return header
    }

    private static func entryArraySize(of header: [UInt8]) throws -> Int {
        let count = Int(uint32(header, at: Field.entryCount))
        let size = Int(uint32(header, at: Field.entrySize))
        let (arraySize, overflows) = count.multipliedReportingOverflow(by: size)
        guard !overflows, size >= shortestEntry, size % 8 == 0, (1...largestEntryArray).contains(arraySize) else {
            throw damaged("its entry array has an unusual size")
        }
        return arraySize
    }

    /// Where `byteCount` bytes from `sector` start, if they end within the disk.
    private static func byteOffset(
        ofSector sector: UInt64, sectorSize: UInt64, holding byteCount: UInt64, onDiskOf size: UInt64
    )
        throws -> UInt64
    {
        let (offset, overflows) = sector.multipliedReportingOverflow(by: sectorSize)
        guard !overflows, offset <= size, byteCount <= size - offset else {
            throw damaged("it points past the end of the disk")
        }
        return offset
    }

    private static func usableSectors(in header: [UInt8], diskSectors: UInt64) throws -> ClosedRange<UInt64> {
        let first = uint64(header, at: Field.firstUsableSector)
        let last = uint64(header, at: Field.lastUsableSector)
        guard first <= last, last < diskSectors else { throw damaged("its usable space lies outside the disk") }
        return first...last
    }

    /// Partitions within the usable sectors, none overlapping another.
    private static func checkedPartitions(in entries: [UInt8], entrySize: Int, within usable: ClosedRange<UInt64>)
        throws -> [Partition]
    {
        let partitions = partitionsInUse(entries, entrySize: entrySize)
        var previousEnd: UInt64?
        for partition in partitions {
            guard partition.firstSector <= partition.lastSector, usable.contains(partition.firstSector),
                usable.contains(partition.lastSector), previousEnd.map({ partition.firstSector > $0 }) ?? true
            else { throw damaged("a partition lies outside the disk or over another") }
            previousEnd = partition.lastSector
        }
        return partitions
    }

    private static func partitionsInUse(_ entries: [UInt8], entrySize: Int) -> [Partition] {
        var partitions: [Partition] = []
        for index in 0..<(entries.count / entrySize) {
            let offset = index * entrySize
            let type = Array(entries[(offset + EntryField.type.lowerBound)..<(offset + EntryField.type.upperBound)])
            guard type.contains(where: { $0 != 0 }) else { continue }
            partitions.append(
                Partition(
                    index: index, type: mixedEndianUUID(type),
                    firstSector: uint64(entries, at: offset + EntryField.firstSector),
                    lastSector: uint64(entries, at: offset + EntryField.lastSector)))
        }
        return partitions.sorted { $0.firstSector < $1.firstSector }
    }

    /// The header's checksum is taken with its own field as zero.
    private static func headerChecksum(_ header: [UInt8]) -> UInt32 {
        var zeroed = header
        setUInt32(&zeroed, at: Field.headerChecksum, 0)
        return CRC32.checksum(zeroed)
    }

    /// GPT stores a GUID's first three fields little-endian and the rest as bytes.
    private static func mixedEndianUUID(_ bytes: [UInt8]) -> UUID {
        let ordered = [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8..<16]
        return UUID(
            uuid: (
                ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
                ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15]
            ))
    }

    private static func damaged(_ problem: String) -> HangarError {
        HangarError("The disk's partition table looks damaged: \(problem).")
    }

    private static func read(_ disk: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try disk.seek(toOffset: offset)
        let data = try disk.readPiece(upToCount: count) ?? Data()
        guard data.count == count else { throw HangarError("The disk ends before its partition table does.") }
        return Array(data)
    }

    private static func write(_ disk: FileHandle, _ bytes: [UInt8], at offset: UInt64) throws {
        try disk.seek(toOffset: offset)
        try disk.write(contentsOf: bytes)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<offset + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func setUInt32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private static func setUInt64(_ bytes: inout [UInt8], at offset: Int, _ value: UInt64) {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}

/// The CRC-32 GPT uses (IEEE 802.3, reflected, as zlib's `crc32`).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
