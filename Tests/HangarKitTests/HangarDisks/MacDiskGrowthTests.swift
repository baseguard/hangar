import Foundation
import HangarSupport
import Testing

@testable import HangarDisks
@testable import HangarKit

/// Moving RecoveryOS on a small disk laid out as macOS lays its disk out, and partition tables that a hostile guest or
/// image could write. The container itself is grown by the agent in the guest.
@Suite(.temporaryHangarHome)
struct MacDiskGrowthTests {
    private static let sector: UInt64 = 512
    private static let mib: UInt64 = 1 << 20
    private static let iscType = "69646961-6700-11AA-AA11-00306543ECAC"
    private static let containerType = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    private static let recoveryType = "52637672-7900-11AA-AA11-00306543ECAC"
    /// RecoveryOS fills the last 4 MiB a 32 MiB disk's partitions may use, as on a VM's disk.
    private static let recovery: ClosedRange<UInt64> = 57_304...65_495

    private var disk: URL { HangarPaths.home.appendingPathComponent("disk.img") }

    @Test func recoveryMovesToTheNewEndWithItsDataAndBothTablesAreSound() throws {
        try makeMacDisk(size: 32 * Self.mib)
        let pattern = try writePattern(at: Self.recovery.lowerBound)

        try MacDiskGrowth.grow(disk, to: 48 * Self.mib)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        let table = try #require(try GUIDPartitionTable.read(from: handle, diskSize: 48 * Self.mib))
        let moved = try #require(table.partitions.last)
        let lastSector = 48 * Self.mib / Self.sector - 1
        #expect(throws: Never.self) { try MacDiskGrowth.checkNoUnfinishedGrowth(of: disk) }
        #expect(moved.sectorCount == UInt64(Self.recovery.count))
        #expect(moved.firstSector % 8 == 0)
        #expect(table.lastUsableSector(onDiskOf: 48 * Self.mib) == lastSector - 33)
        #expect(try moved.lastSector <= #require(table.lastUsableSector(onDiskOf: 48 * Self.mib)))
        #expect(try read(at: moved.firstSector * Self.sector, count: pattern.count) == pattern)
        #expect(try read(at: lastSector * Self.sector, count: 8) == Array("EFI PART".utf8))
        #expect(MacDiskGrowth.isMacDisk(disk))
    }

    /// The VM's system decides, never the disk's contents: a Linux VM whose disk looks like macOS's only grows as a file,
    /// so nothing in it is moved.
    @Test func aDiskThatLooksLikeMacOSOnlyGrowsAsAFileInALinuxVM() throws {
        try makeMacDisk(size: 32 * Self.mib)
        let bundle = VMBundle(url: HangarPaths.home)

        try bundle.resizeDisk(to: 48 * Self.mib, os: .linux)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        let table = try #require(try GUIDPartitionTable.read(from: handle, diskSize: 48 * Self.mib))
        #expect(bundle.diskSize == 48 * Self.mib)
        #expect(table.partitions.last?.firstSector == Self.recovery.lowerBound)
    }

    /// When the disk grows by less than RecoveryOS's size, its new place overlaps the old one.
    @Test func recoveryMovesIntactWhenItsNewPlaceOverlapsTheOld() throws {
        try makeMacDisk(size: 32 * Self.mib)
        let pattern = try writePattern(at: Self.recovery.lowerBound)

        try MacDiskGrowth.moveRecoveryToTheEnd(of: disk, growingTo: 34 * Self.mib)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        let moved = try #require(try GUIDPartitionTable.read(from: handle, diskSize: 34 * Self.mib)?.partitions.last)
        #expect(moved.firstSector > Self.recovery.lowerBound)
        #expect(moved.firstSector < Self.recovery.upperBound)
        #expect(try read(at: moved.firstSector * Self.sector, count: pattern.count) == pattern)
    }

    @Test func aDiskWithoutRecoveryOSLastIsNotAMacDisk() throws {
        try makeMacDisk(size: 32 * Self.mib, lastType: Self.containerType)

        #expect(!MacDiskGrowth.isMacDisk(disk))
        #expect(!MacDiskGrowth.isMacDisk(HangarPaths.home.appendingPathComponent("missing.img")))
    }

    @Test func aDamagedTableIsAnErrorNotAnEmptyOne() throws {
        try makeMacDisk(size: 32 * Self.mib)
        try write([0xFF], at: Self.sector + 40)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }

        #expect(throws: HangarError.self) { try GUIDPartitionTable.read(from: handle, diskSize: 32 * Self.mib) }
        #expect(!MacDiskGrowth.isMacDisk(disk))
    }

    /// Numbers a guest controls used to overflow or point past the disk and crash Hangar with every VM in it; each
    /// table below has valid checksums.
    @Test(arguments: HostileTable.allCases)
    func aHostileTableIsAnErrorNotACrash(table: HostileTable) throws {
        try makeMacDisk(size: 32 * Self.mib, hostile: table)

        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }

        #expect(throws: HangarError.self) { try GUIDPartitionTable.read(from: handle, diskSize: 32 * Self.mib) }
        #expect(!MacDiskGrowth.isMacDisk(disk))
    }

    @Test func aFailedGrowthLeavesTheDiskAsItWasAndNoCopy() throws {
        try makeMacDisk(size: 32 * Self.mib)
        let before = try Data(contentsOf: disk)

        #expect(throws: HangarError.self) { try MacDiskGrowth.grow(disk, to: 32 * Self.mib + 100) }

        #expect(try Data(contentsOf: disk) == before)
        #expect(throws: Never.self) { try MacDiskGrowth.checkNoUnfinishedGrowth(of: disk) }
    }

    /// A copy from before a growth is either a growth that stopped half-way or one whose cleanup failed; the disk is
    /// neither grown again nor started until the user decides.
    @Test func aCopyLeftFromAnEarlierGrowthStopsTheNextOne() throws {
        try makeMacDisk(size: 32 * Self.mib)
        try Data("before".utf8).write(to: disk.appendingPathExtension("before-growing"))

        #expect(throws: HangarError.self) { try MacDiskGrowth.checkNoUnfinishedGrowth(of: disk) }
        #expect(throws: HangarError.self) { try MacDiskGrowth.grow(disk, to: 48 * Self.mib) }
    }

    enum HostileTable: CaseIterable {
        /// 0xFFFFFFFF entries of 0xFFFFFFF8 bytes.
        case entryArrayOverflows
        /// The array's sector times the sector size overflows.
        case entryArrayPastEveryDisk
        case partitionEndsBeforeItStarts
        case partitionPastTheUsableSpace
        case partitionsOverlap
    }

    /// ISC, the main container, then RecoveryOS (or `lastType`), with the GPT's two copies and a protective MBR.
    private func makeMacDisk(size: UInt64, lastType: String = recoveryType, hostile: HostileTable? = nil) throws {
        try SparseFile.create(at: disk, size: size, truncateExisting: true)
        let lastSector = size / Self.sector - 1
        var entries = [UInt8](repeating: 0, count: 128 * 128)
        try addEntry(0, type: Self.iscType, sectors: 40...2_087, to: &entries)
        try addEntry(1, type: Self.containerType, sectors: 2_088...57_303, to: &entries)
        try addEntry(2, type: lastType, sectors: Self.recovery, to: &entries)
        if let hostile { spoil(hostile, entries: &entries) }

        var primary = header(current: 1, backup: lastSector, entriesAt: 2, entries: entries)
        if let hostile { spoil(hostile, header: &primary) }
        try write(protectiveMBR(sectorCount: lastSector + 1), at: 0)
        try write(entries, at: 2 * Self.sector)
        try write(primary, at: Self.sector)
        try write(entries, at: (lastSector - 32) * Self.sector)
        try write(
            header(current: lastSector, backup: 1, entriesAt: lastSector - 32, entries: entries),
            at: lastSector * Self.sector)
    }

    private func spoil(_ hostile: HostileTable, entries: inout [UInt8]) {
        switch hostile {
        case .partitionEndsBeforeItStarts:
            put(Self.recovery.upperBound, at: 2 * 128 + 32, in: &entries)
            put(Self.recovery.lowerBound, at: 2 * 128 + 40, in: &entries)
        case .partitionPastTheUsableSpace:
            put(UInt64.max - 1, at: 2 * 128 + 40, in: &entries)
        case .partitionsOverlap:
            put(Self.recovery.lowerBound + 8, at: 1 * 128 + 40, in: &entries)
        case .entryArrayOverflows, .entryArrayPastEveryDisk:
            break
        }
    }

    /// Changes the primary header, then checksums it again so only the numbers are wrong.
    private func spoil(_ hostile: HostileTable, header: inout [UInt8]) {
        switch hostile {
        case .entryArrayOverflows:
            put(0xFFFF_FFF8 << 32 | 0xFFFF_FFFF, at: 80, in: &header)
        case .entryArrayPastEveryDisk:
            put(UInt64.max / 2, at: 72, in: &header)
        case .partitionEndsBeforeItStarts, .partitionPastTheUsableSpace, .partitionsOverlap:
            return
        }
        put(0, at: 16, in: &header, width: 4)
        put(UInt64(CRC32.checksum(header)), at: 16, in: &header, width: 4)
    }

    private func addEntry(_ index: Int, type: String, sectors: ClosedRange<UInt64>, to entries: inout [UInt8]) throws {
        let offset = index * 128
        let uuid = try #require(UUID(uuidString: type)).uuid
        let bytes = withUnsafeBytes(of: uuid) { Array($0) }
        let mixedEndian =
            [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
        entries.replaceSubrange(offset..<offset + 16, with: mixedEndian)
        put(sectors.lowerBound, at: offset + 32, in: &entries)
        put(sectors.upperBound, at: offset + 40, in: &entries)
    }

    private func header(current: UInt64, backup: UInt64, entriesAt: UInt64, entries: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 92)
        header.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        put(UInt64(0x0001_0000) | UInt64(92) << 32, at: 8, in: &header)
        put(current, at: 24, in: &header)
        put(backup, at: 32, in: &header)
        put(34, at: 40, in: &header)
        put(max(current, backup) - 33, at: 48, in: &header)
        put(entriesAt, at: 72, in: &header)
        put(UInt64(128) | UInt64(128) << 32, at: 80, in: &header)
        put(UInt64(CRC32.checksum(entries)), at: 88, in: &header, width: 4)
        put(UInt64(CRC32.checksum(header)), at: 16, in: &header, width: 4)
        return header
    }

    private func protectiveMBR(sectorCount: UInt64) -> [UInt8] {
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[446 + 4] = 0xEE
        put(1, at: 446 + 8, in: &mbr, width: 4)
        put(sectorCount - 1, at: 446 + 12, in: &mbr, width: 4)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    private func put(_ value: UInt64, at offset: Int, in bytes: inout [UInt8], width: Int = 8) {
        for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    /// Bytes that differ along RecoveryOS's first MiB, so a piece copied to the wrong place shows.
    private func writePattern(at firstSector: UInt64) throws -> [UInt8] {
        let pattern = (0..<Int(Self.mib)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }
        try write(pattern, at: firstSector * Self.sector)
        return pattern
    }

    private func write(_ bytes: [UInt8], at offset: UInt64) throws {
        let handle = try FileHandle(forUpdating: disk)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: bytes)
    }

    private func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return Array(try handle.read(upToCount: count) ?? Data())
    }
}
