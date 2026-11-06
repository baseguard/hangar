import Foundation
import HangarSupport

package struct FATVolume {
    private let handle: FileHandle
    private let fileSize: UInt64
    private let bytesPerSector: UInt64
    private let bytesPerCluster: UInt64
    private let fatOffset: UInt64
    private let dataOffset: UInt64
    private let clusterCount: UInt64
    private let rootCluster: UInt32

    private static let maxDirectoryEntries = 65_536
    /// 255 characters take at most 20 long-name entries of 13 each.
    private static let longestName = 20 * 13

    /// A directory entry's layout: its attribute byte, and the fields of a file's entry.
    private static let entrySize = 32
    private static let deletedEntry: UInt8 = 0xE5
    private static let attributesOffset = 11
    private static let attributeMask: UInt8 = 0x3F
    private static let longNameAttributes: UInt8 = 0x0F
    private static let volumeLabelAttribute: UInt8 = 0x08
    private static let directoryAttribute: UInt8 = 0x10
    private static let firstClusterHighOffset = 20
    private static let firstClusterLowOffset = 26
    private static let sizeOffset = 28

    package init(image url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        let partition = try Self.firstPartition(handle, fileSize: fileSize)
        let bpb = try Self.read(handle, at: partition.offset, count: 512, fileSize: fileSize)
        let boot = try BootSector(bpb, partitionSectors: partition.sectors)

        let dataStartSector = boot.reservedSectors + boot.fatSize * boot.fatCount
        guard dataStartSector < boot.totalSectors, boot.fatSize <= boot.totalSectors else {
            throw Self.unreadable("the FAT32 layout is inconsistent")
        }
        bytesPerSector = boot.bytesPerSector
        bytesPerCluster = boot.bytesPerSector * boot.sectorsPerCluster
        fatOffset = partition.offset + boot.reservedSectors * boot.bytesPerSector
        dataOffset = partition.offset + dataStartSector * boot.bytesPerSector
        clusterCount = (boot.totalSectors - dataStartSector) / boot.sectorsPerCluster
        rootCluster = boot.rootCluster
        guard clusterCount >= 1, UInt64(rootCluster) < clusterCount + 2,
            (clusterCount + 2) * 4 <= boot.fatSize * boot.bytesPerSector
        else {
            throw Self.unreadable("the FAT32 layout is inconsistent")
        }
    }

    private static func firstPartition(
        _ handle: FileHandle, fileSize: UInt64
    ) throws -> (offset: UInt64, sectors: UInt64) {
        let mbr = try read(handle, at: 0, count: 512, fileSize: fileSize)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else { throw unreadable("no partition table") }
        let start = UInt64(readUInt32(mbr, at: 446 + 8))
        let sectors = UInt64(readUInt32(mbr, at: 446 + 12))
        guard start > 0, sectors > 0, let end = checked(start + sectors, times: 512), end <= fileSize else {
            throw unreadable("the first partition is outside the image")
        }
        return (start * 512, sectors)
    }

    private struct BootSector {
        let bytesPerSector: UInt64
        let sectorsPerCluster: UInt64
        let reservedSectors: UInt64
        let fatCount: UInt64
        let fatSize: UInt64
        let rootCluster: UInt32
        let totalSectors: UInt64

        init(_ bpb: [UInt8], partitionSectors: UInt64) throws {
            bytesPerSector = UInt64(readUInt16(bpb, at: 11))
            sectorsPerCluster = UInt64(bpb[13])
            reservedSectors = UInt64(readUInt16(bpb, at: 14))
            fatCount = UInt64(bpb[16])
            fatSize = UInt64(readUInt32(bpb, at: 36))
            rootCluster = readUInt32(bpb, at: 44)
            let totalSectors16 = UInt64(readUInt16(bpb, at: 19))
            totalSectors = totalSectors16 == 0 ? UInt64(readUInt32(bpb, at: 32)) : totalSectors16

            let isFAT32 = readUInt16(bpb, at: 17) == 0 && readUInt16(bpb, at: 22) == 0 && fatSize > 0
            guard isFAT32, [512, 1024, 2048, 4096].contains(bytesPerSector),
                sectorsPerCluster > 0, sectorsPerCluster <= 128, sectorsPerCluster & (sectorsPerCluster - 1) == 0,
                reservedSectors >= 1, fatCount == 1 || fatCount == 2, rootCluster >= 2,
                totalSectors > 0, totalSectors <= partitionSectors * 512 / bytesPerSector
            else {
                throw unreadable("the first partition is not FAT32")
            }
        }
    }

    package func close() {
        try? handle.close()
    }

    package func readFile(_ path: [String], limit: Int) throws -> Data? {
        var directory = rootCluster
        for (index, component) in path.enumerated() {
            guard let entry = try find(component, in: directory) else { return nil }
            if index == path.count - 1 {
                guard !entry.isDirectory else { return nil }
                return try contents(of: entry, limit: limit)
            }
            guard entry.isDirectory, entry.firstCluster >= 2 else { return nil }
            directory = entry.firstCluster
        }
        return nil
    }

    private struct Entry {
        var firstCluster: UInt32
        var size: UInt32
        var isDirectory: Bool
    }

    private func find(_ name: String, in directory: UInt32) throws -> Entry? {
        let wanted = name.uppercased()
        var longName: [UInt16] = []
        var scanned = 0

        for cluster in try chain(from: directory) {
            let block = try read(cluster: cluster)
            for offset in stride(from: 0, to: block.count, by: Self.entrySize) {
                scanned += 1
                guard scanned <= Self.maxDirectoryEntries else { throw Self.unreadable("a directory is too long") }
                let entry = Array(block[offset..<(offset + Self.entrySize)])
                if entry[0] == 0 { return nil }
                if entry[0] == Self.deletedEntry {
                    longName = []
                    continue
                }

                let attributes = entry[Self.attributesOffset]
                if attributes & Self.attributeMask == Self.longNameAttributes {
                    guard longName.count < Self.longestName else { throw Self.unreadable("a file name is too long") }
                    longName = Self.longNamePart(entry[...]) + longName
                    continue
                }

                // The long name belongs to this entry, whatever it is; the next one starts afresh.
                let long = String(decoding: longName, as: UTF16.self).uppercased()
                longName = []
                if let found = Self.entry(entry, ifNamed: wanted, orLong: long) { return found }
            }
        }

        return nil
    }

    /// The entry when its short or long name is the wanted one; a volume label never is.
    private static func entry(_ bytes: [UInt8], ifNamed wanted: String, orLong long: String) -> Entry? {
        let attributes = bytes[attributesOffset]
        if attributes & volumeLabelAttribute != 0 { return nil }
        guard shortName(bytes[...]) == wanted || (!long.isEmpty && long == wanted) else { return nil }

        let high = UInt32(readUInt16(bytes, at: firstClusterHighOffset))
        let low = UInt32(readUInt16(bytes, at: firstClusterLowOffset))
        return Entry(
            firstCluster: high << 16 | low, size: readUInt32(bytes, at: sizeOffset),
            isDirectory: attributes & directoryAttribute != 0)
    }

    private func contents(of entry: Entry, limit: Int) throws -> Data {
        var remaining = min(Int(entry.size), limit)
        var data = Data()
        guard remaining > 0, entry.firstCluster >= 2 else { return data }
        for cluster in try chain(from: entry.firstCluster) {
            let block = try read(cluster: cluster)
            data.append(contentsOf: block.prefix(remaining))
            remaining -= min(remaining, block.count)
            if remaining == 0 { break }
        }
        return data
    }

    private func chain(from first: UInt32) throws -> [UInt32] {
        var clusters: [UInt32] = []
        var visited = Set<UInt32>()
        var current = first
        while current >= 2, current < 0x0FFF_FFF8 {
            guard current != 0x0FFF_FFF7, UInt64(current) < clusterCount + 2, visited.insert(current).inserted else {
                throw Self.unreadable("a cluster chain is corrupt")
            }
            clusters.append(current)
            let raw = try Self.read(handle, at: fatOffset + UInt64(current) * 4, count: 4, fileSize: fileSize)
            current = Self.readUInt32(raw, at: 0) & 0x0FFF_FFFF
        }
        return clusters
    }

    private func read(cluster: UInt32) throws -> [UInt8] {
        try Self.read(
            handle, at: dataOffset + UInt64(cluster - 2) * bytesPerCluster, count: Int(bytesPerCluster),
            fileSize: fileSize)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int, fileSize: UInt64) throws -> [UInt8] {
        guard let end = checked(offset, plus: UInt64(count)), end <= fileSize else {
            throw unreadable("a read is outside the image")
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readPiece(upToCount: count), data.count == count else {
            throw unreadable("the image is truncated")
        }
        return [UInt8](data)
    }

    private static func shortName(_ entry: ArraySlice<UInt8>) -> String {
        let bytes = Array(entry.prefix(11))
        let base = String(decoding: bytes[0..<8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ext = String(decoding: bytes[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return (ext.isEmpty ? base : "\(base).\(ext)").uppercased()
    }

    private static func longNamePart(_ entry: ArraySlice<UInt8>) -> [UInt16] {
        let bytes = Array(entry)
        var units: [UInt16] = []
        for offset in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] {
            let unit = readUInt16(bytes, at: offset)
            if unit == 0 || unit == 0xFFFF { break }
            units.append(unit)
        }
        return units
    }

    private static func checked(_ a: UInt64, plus b: UInt64) -> UInt64? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }

    private static func checked(_ a: UInt64, times b: UInt64) -> UInt64? {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : product
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(
            bytes[offset + 3]) << 24
    }

    private static func unreadable(_ detail: String) -> HangarError {
        HangarError("Could not read the Windows installation media: \(detail).")
    }
}
