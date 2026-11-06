import Foundation
import HangarSupport

package enum ISOImage {
    static let sectorSize = 2048
    /// ECMA-119 starts the volume descriptors at sector 16; this image puts its path tables and root right after.
    private static let primaryDescriptorSector = 16
    private static let terminatorSector = 17
    private static let littleEndianPathTableSector = 18
    private static let bigEndianPathTableSector = 19
    private static let rootSector = 20
    private static let standardIdentifier = Array("CD001".utf8)
    private static let primaryDescriptorType: UInt8 = 1
    private static let terminatorType: UInt8 = 255
    private static let unreadable = HangarError("This is not a readable ISO image.")

    /// The primary volume descriptor's fields, by byte offset (ECMA-119 §8.4).
    private enum Descriptor {
        static let systemIdentifier = 8
        static let volumeIdentifier = 40
        static let volumeSpaceSize = 80
        static let volumeSetSize = 120
        static let volumeSequenceNumber = 124
        static let logicalBlockSize = 128
        static let pathTableSize = 132
        static let littleEndianPathTable = 140
        static let bigEndianPathTable = 148
        static let rootDirectoryRecord = 156
        /// The volume set, publisher, preparer, application and file identifiers, blank here.
        static let identifiers = 190
        static let identifiersLength = 623
        static let creationDate = 813
        static let modificationDate = 830
        static let expirationDate = 847
        static let effectiveDate = 864
        static let fileStructureVersion = 881
    }

    /// A directory record's fields, by byte offset (ECMA-119 §9.1).
    private enum Record {
        static let extent = 2
        static let size = 10
        static let flags = 25
        static let nameLength = 32
        static let name = 33
        static let shortest = 34
        static let directoryFlag: UInt8 = 2
    }

    package static func make(files: [(name: String, data: Data)], volume: String) throws -> Data {
        let sorted = files.map { (identifier: $0.name.uppercased() + ";1", data: $0.data) }.sorted {
            $0.identifier < $1.identifier
        }

        var extents: [Int] = []
        var next = rootSector + 1
        for file in sorted {
            extents.append(next)
            next += max(1, sectors(for: file.data.count))
        }

        let date = Date()

        var root = directoryRecord(identifier: [0], extent: rootSector, size: sectorSize, isDirectory: true, date: date)
        root += directoryRecord(identifier: [1], extent: rootSector, size: sectorSize, isDirectory: true, date: date)
        for (file, extent) in zip(sorted, extents) {
            root += directoryRecord(
                identifier: Array(file.identifier.utf8), extent: extent, size: file.data.count, isDirectory: false,
                date: date)
        }
        guard root.count <= sectorSize else { throw HangarError("Too many files for one ISO directory.") }

        var image = Data(count: next * sectorSize)
        func put(_ bytes: [UInt8], inSector sector: Int) {
            image.replaceSubrange(sector * sectorSize..<sector * sectorSize + bytes.count, with: bytes)
        }
        put(primaryDescriptor(volume: volume, sectors: next, date: date), inSector: primaryDescriptorSector)
        put([terminatorType] + standardIdentifier + [1], inSector: terminatorSector)
        put(pathTable(bigEndian: false), inSector: littleEndianPathTableSector)
        put(pathTable(bigEndian: true), inSector: bigEndianPathTableSector)
        put(root, inSector: rootSector)
        for (file, extent) in zip(sorted, extents) {
            put(Array(file.data), inSector: extent)
        }
        return image
    }

    package static func files(in image: Data) throws -> [String: Data] {
        let bytes = [UInt8](image)
        let descriptor = primaryDescriptorSector * sectorSize
        guard bytes.count >= descriptor + sectorSize, bytes[descriptor] == primaryDescriptorType,
            Array(bytes[descriptor + 1..<descriptor + 6]) == standardIdentifier
        else {
            throw unreadable
        }

        let root = try number(bytes, at: descriptor + Descriptor.rootDirectoryRecord + Record.extent) * sectorSize
        guard root >= 0, root + sectorSize <= bytes.count else { throw unreadable }

        var files: [String: Data] = [:]
        var offset = root
        while offset < root + sectorSize, bytes[offset] > 0 {
            let length = Int(bytes[offset])
            guard length >= Record.shortest, offset + length <= root + sectorSize else { throw unreadable }
            if let file = try file(recordAt: offset, length: length, in: bytes) { files[file.name] = file.data }
            offset += length
        }

        return files
    }

    /// The file a directory record names, with its contents; a directory record gives nothing.
    private static func file(recordAt offset: Int, length: Int, in bytes: [UInt8]) throws -> (name: String, data: Data)?
    {
        let nameLength = Int(bytes[offset + Record.nameLength])
        guard Record.name + nameLength <= length else { throw unreadable }
        if bytes[offset + Record.flags] & Record.directoryFlag != 0 { return nil }

        let nameStart = offset + Record.name
        let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
        let start = try number(bytes, at: offset + Record.extent) * sectorSize
        let size = try number(bytes, at: offset + Record.size)
        guard start >= 0, size >= 0, start + size <= bytes.count else { throw unreadable }
        return (name.lowercased().replacingOccurrences(of: ";1", with: ""), Data(bytes[start..<start + size]))
    }

    /// The little-endian half of a both-byte-orders number (ECMA-119 §7.3.3).
    private static func number(_ bytes: [UInt8], at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw unreadable }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }

    private static func sectors(for size: Int) -> Int {
        (size + sectorSize - 1) / sectorSize
    }

    private static func primaryDescriptor(volume: String, sectors: Int, date: Date) -> [UInt8] {
        var descriptor = [UInt8](repeating: 0, count: sectorSize)
        func put(_ bytes: [UInt8], at offset: Int) {
            descriptor.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }

        func text(_ value: String, length: Int) -> [UInt8] {
            Array((value.uppercased() + String(repeating: " ", count: length)).utf8.prefix(length))
        }
        put([primaryDescriptorType] + standardIdentifier + [1], at: 0)
        put(text("", length: 32), at: Descriptor.systemIdentifier)
        put(text(volume, length: 32), at: Descriptor.volumeIdentifier)
        put(bothEndian32(sectors), at: Descriptor.volumeSpaceSize)
        put(bothEndian16(1), at: Descriptor.volumeSetSize)
        put(bothEndian16(1), at: Descriptor.volumeSequenceNumber)
        put(bothEndian16(sectorSize), at: Descriptor.logicalBlockSize)
        put(bothEndian32(pathTable(bigEndian: false).count), at: Descriptor.pathTableSize)
        put(littleEndian32(littleEndianPathTableSector), at: Descriptor.littleEndianPathTable)
        put(bigEndian32(bigEndianPathTableSector), at: Descriptor.bigEndianPathTable)
        put(
            directoryRecord(identifier: [0], extent: rootSector, size: sectorSize, isDirectory: true, date: date),
            at: Descriptor.rootDirectoryRecord)
        put(text("", length: Descriptor.identifiersLength), at: Descriptor.identifiers)
        let stamp = descriptorDate(date)
        put(stamp, at: Descriptor.creationDate)
        put(stamp, at: Descriptor.modificationDate)
        put(Array(String(repeating: "0", count: 16).utf8) + [0], at: Descriptor.expirationDate)
        put(stamp, at: Descriptor.effectiveDate)
        put([1], at: Descriptor.fileStructureVersion)

        return descriptor
    }

    private static func pathTable(bigEndian: Bool) -> [UInt8] {
        [1, 0] + (bigEndian ? bigEndian32(rootSector) : littleEndian32(rootSector)) + (bigEndian ? [0, 1] : [1, 0]) + [
            0, 0,
        ]
    }

    private static func directoryRecord(identifier: [UInt8], extent: Int, size: Int, isDirectory: Bool, date: Date)
        -> [UInt8]
    {
        let padding = identifier.count % 2 == 0 ? 1 : 0
        var record: [UInt8] = [UInt8(Record.name + identifier.count + padding), 0]
        record += bothEndian32(extent) + bothEndian32(size) + recordDate(date)
        record += [isDirectory ? Record.directoryFlag : 0, 0, 0] + bothEndian16(1) + [UInt8(identifier.count)]
        record += identifier
        return record + Array(repeating: 0, count: padding)
    }

    private static func recordDate(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        func part(_ component: Calendar.Component) -> UInt8 { UInt8(calendar.component(component, from: date)) }

        let yearsSince1900 = UInt8(calendar.component(.year, from: date) - 1900)
        return [yearsSince1900, part(.month), part(.day), part(.hour), part(.minute), part(.second), 0]
    }

    private static func descriptorDate(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMddHHmmss'00'"
        return Array(formatter.string(from: date).utf8) + [0]
    }

    private static func littleEndian32(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)
    }

    private static func bigEndian32(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value).bigEndian, Array.init)
    }

    private static func bothEndian32(_ value: Int) -> [UInt8] {
        littleEndian32(value) + bigEndian32(value)
    }

    private static func bothEndian16(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)
            + withUnsafeBytes(of: UInt16(value).bigEndian, Array.init)
    }
}
