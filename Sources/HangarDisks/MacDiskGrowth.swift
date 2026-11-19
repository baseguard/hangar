import Darwin
import Foundation
import HangarSupport

/// Makes room for a macOS guest to use a disk that grew. macOS lays its disk out as ISC, the main APFS container, then
/// RecoveryOS, so space added at the end of the file lies behind RecoveryOS, where the container can't reach it.
/// Growing moves RecoveryOS to the new end, whole and under its own partition id, and writes the partition table for
/// the new size; Hangar's agent in the guest then grows the container into the space between when macOS starts. This
/// Mac only reads and writes the file: it never attaches the disk, so the guest's file systems are never read here.
/// It works next to a copy-on-write clone of the disk, and a failed step puts that clone back.
package enum MacDiskGrowth {
    private static let apfsContainer = UUID(uuidString: "7C3457EF-0000-11AA-AA11-00306543ECAC")
    private static let apfsRecovery = UUID(uuidString: "52637672-7900-11AA-AA11-00306543ECAC")
    /// macOS starts its partitions on 4 KiB.
    private static let alignment: UInt64 = 4096
    private static let copyPiece: UInt64 = 8 << 20

    /// The main container, and RecoveryOS as the last partition right after it.
    private struct Layout {
        var table: GUIDPartitionTable
        let recovery: GUIDPartitionTable.Partition
    }

    /// False for any other disk, and for one whose partition table can't be read; those only grow as a file.
    package static func isMacDisk(_ disk: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: disk) else { return false }
        defer { try? handle.close() }
        return (try? layout(of: handle)) != nil
    }

    /// A copy left from before a growth means it stopped half-way, as when Hangar was stopped, or that only its
    /// cleanup failed. Putting the copy back and growing again is safe either way, so the message leads with it.
    package static func checkNoUnfinishedGrowth(of disk: URL) throws {
        let backup = backupURL(for: disk)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        throw HangarError(
            "\(backup.path) is \(disk.lastPathComponent) as it was before a growth that didn't finish. Put it back in place of \(disk.lastPathComponent) and grow the disk again. Only if Hangar said the disk grew but this copy stayed, delete the copy instead."
        )
    }

    package static func grow(_ disk: URL, to size: UInt64) throws {
        try checkNoUnfinishedGrowth(of: disk)
        let backup = backupURL(for: disk)
        try cloneForRollback(disk, to: backup)
        do {
            try moveRecoveryToTheEnd(of: disk, growingTo: size)
        } catch {
            restore(disk, from: backup)
            throw HangarError(
                "Could not grow \(disk.lastPathComponent), so it is as it was: \(error.localizedDescription)")
        }
        try removeBackup(backup)
    }

    private static func backupURL(for disk: URL) -> URL {
        disk.appendingPathExtension("before-growing")
    }

    /// A clone shares the disk's blocks, so it costs nothing until the disk changes.
    private static func cloneForRollback(_ disk: URL, to backup: URL) throws {
        guard clonefile(disk.path, backup.path, 0) == 0 else {
            throw HangarError(
                errno: errno, "Could not keep a copy of \(disk.lastPathComponent) to go back to while it grows")
        }
    }

    private static func restore(_ disk: URL, from backup: URL) {
        guard rename(backup.path, disk.path) == 0 else {
            let reason = String(cString: strerror(errno))
            HangarLog.warning("Could not put back \(disk.path) (\(reason)); the disk from before is \(backup.path).")
            return
        }
    }

    private static func removeBackup(_ backup: URL) throws {
        do {
            try FileManager.default.removeItem(at: backup)
        } catch {
            throw HangarError(
                "The disk grew, but its copy from before stays at \(backup.path): delete it before you start the VM (\(error.localizedDescription))."
            )
        }
    }

    static func moveRecoveryToTheEnd(of disk: URL, growingTo size: UInt64) throws {
        let handle = try FileHandle(forUpdating: disk)
        defer { try? handle.close() }
        guard var layout = try layout(of: handle) else {
            throw HangarError("\(disk.lastPathComponent) isn't laid out as macOS lays out its disk.")
        }
        let sectorSize = layout.table.sectorSize
        let oldSize = try handle.seekToEnd()
        guard size > oldSize, size % sectorSize == 0 else {
            throw HangarError("A disk grows to a larger size in whole sectors (now \(ByteSize.format(oldSize))).")
        }

        let target = try recoveryTarget(layout, diskSize: size)
        try handle.truncate(atOffset: size)
        try copy(layout.recovery, toFirstSector: target, in: handle, sectorSize: sectorSize, freshFrom: oldSize)
        layout.table.move(layout.recovery, toFirstSector: target)
        try layout.table.write(to: handle, diskSize: size)
        try handle.synchronize()
    }

    /// The table has checked that its partitions lie within the disk and don't overlap, so the container ends before
    /// RecoveryOS starts.
    private static func layout(of disk: FileHandle) throws -> Layout? {
        let size = try disk.seekToEnd()
        guard let table = try GUIDPartitionTable.read(from: disk, diskSize: size) else { return nil }
        let partitions = table.partitions
        guard partitions.count >= 2, let recovery = partitions.last, recovery.type == apfsRecovery,
            partitions[partitions.count - 2].type == apfsContainer
        else { return nil }
        return Layout(table: table, recovery: recovery)
    }

    /// RecoveryOS's first sector on the grown disk: as near the end as fits, on macOS's alignment.
    private static func recoveryTarget(_ layout: Layout, diskSize size: UInt64) throws -> UInt64 {
        let sectorsPerAlignment = max(1, alignment / layout.table.sectorSize)
        guard let lastUsable = layout.table.lastUsableSector(onDiskOf: size),
            lastUsable + 1 >= layout.recovery.sectorCount
        else { throw HangarError("The grown disk is too small for its partitions.") }
        let first = (lastUsable + 1 - layout.recovery.sectorCount) / sectorsPerAlignment * sectorsPerAlignment
        guard first > layout.recovery.firstSector else {
            throw HangarError("Grow the disk by more: the new space must make room to move RecoveryOS.")
        }
        return first
    }

    /// Copies from the end backward, since the new place overlaps the old one when the disk grows by less than
    /// RecoveryOS's size. Space past the old end of the file reads as zeros already, so zero pieces there are left as
    /// holes and the disk stays sparse.
    private static func copy(
        _ partition: GUIDPartitionTable.Partition, toFirstSector target: UInt64, in disk: FileHandle,
        sectorSize: UInt64, freshFrom oldSize: UInt64
    ) throws {
        let source = partition.firstSector * sectorSize
        let destination = target * sectorSize
        var remaining = partition.sectorCount * sectorSize
        while remaining > 0 {
            let count = min(remaining, copyPiece)
            remaining -= count
            try disk.seek(toOffset: source + remaining)
            let piece = try disk.readPiece(upToCount: Int(count)) ?? Data()
            guard piece.count == Int(count) else { throw HangarError("The disk ends inside RecoveryOS.") }
            if destination + remaining >= oldSize, isAllZero(piece) { continue }
            try disk.seek(toOffset: destination + remaining)
            try disk.write(contentsOf: piece)
        }
    }

    private static func isAllZero(_ piece: Data) -> Bool {
        piece.withUnsafeBytes { bytes in
            let words = bytes.count / 8
            for word in 0..<words where bytes.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) != 0 {
                return false
            }
            return bytes[(words * 8)...].allSatisfy { $0 == 0 }
        }
    }
}
