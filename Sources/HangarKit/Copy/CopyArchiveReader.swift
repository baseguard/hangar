import Foundation
import HangarDisks
import HangarSupport

/// Reads `CopyArchive`'s stream as it arrives, one entry at a time, holding one block and the bytes of one frame. The
/// guest made the stream, so it is checked as it is read: a damaged header, an oversized PAX record or a name that
/// isn't UTF-8 stops it.
struct CopyArchiveReader {
    enum Item {
        case entry(CopyArchive.Header)
        /// A link, a device or anything else that isn't a file or folder; nothing of it is written.
        case skipped(name: String)
    }

    static let largestPaxHeader = 64 << 10
    /// No entry of a copy is larger, so a size from the guest can't overflow the arithmetic below.
    static let largestEntry = CopyExtractor.largestCopy
    static let longestName = 4 << 10

    private let source: () throws -> Data?
    private var buffer = Data()
    private var isAtEnd = false

    /// `source` gives the next bytes of the stream, or nil at its end.
    init(source: @escaping () throws -> Data?) {
        self.source = source
    }

    /// The next entry, or nil at the end of the archive.
    mutating func next() throws -> Item? {
        var pax: [String: String] = [:]
        var longName: String?

        while true {
            guard let header = try header() else { return nil }
            let type = header[Tar.typeField]
            let size = try pax["size"].map(Self.decimal) ?? Self.octal(header[Tar.sizeField])
            guard size <= Self.largestEntry else { throw HangarError("The copy from the VM has an oversized entry.") }

            switch type {
            case UInt8(ascii: "x"):
                pax = try paxRecords(size: size)
            case UInt8(ascii: "g"):
                try skip(size + Tar.padding(after: size))
            case UInt8(ascii: "L"):
                longName = try longNameRecord(size: size)
            default:
                let name = try pax["path"] ?? longName ?? Self.name(in: header)
                let modified = Date(
                    timeIntervalSince1970: TimeInterval(try Self.octal(header[Tar.modifiedField])))
                return try item(type: type, name: name, size: size, mode: header[100..<108], modified: modified)
            }
        }
    }

    /// Hands the entry's bytes to `write` in pieces, then skips its padding.
    mutating func readData(of header: CopyArchive.Header, into write: (Data) throws -> Void) throws {
        var left = header.size
        while left > 0 {
            let piece = try take(Int(min(left, UInt64(ExecFrame.maximumPayload))))
            try write(piece)
            left -= UInt64(piece.count)
        }
        try skip(Tar.padding(after: header.size))
    }

    /// Skips a skipped item's bytes.
    mutating func skipData(size: UInt64) throws {
        try skip(size + Tar.padding(after: size))
    }

    private mutating func item(type: UInt8, name: String, size: UInt64, mode: ArraySlice<UInt8>, modified: Date) throws
        -> Item
    {
        switch type {
        case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
            let isExecutable = (try Self.octal(mode)) & 0o111 != 0
            return .entry(.init(name: name, kind: .file(isExecutable: isExecutable), size: size, modified: modified))
        case UInt8(ascii: "5"):
            try skip(size + Tar.padding(after: size))
            return .entry(.init(name: name, kind: .folder, size: 0, modified: modified))
        default:
            try skip(size + Tar.padding(after: size))
            return .skipped(name: name)
        }
    }

    /// The next header block; nil at the zero block that ends the archive. A stream that stops before it was cut
    /// off, so it fails rather than look like a smaller copy.
    private mutating func header() throws -> ArraySlice<UInt8>? {
        guard try fill(Tar.blockSize) else { throw HangarError("The copy from the VM ended early.") }
        let block = [UInt8](try take(Tar.blockSize))[...]
        if block.allSatisfy({ $0 == 0 }) { return nil }
        let stored = try Self.octal(block[Tar.checksumField])
        guard stored == UInt64(Tar.checksum(of: Array(block))) else {
            throw HangarError("The copy from the VM has a damaged header.")
        }
        return block
    }

    private mutating func paxRecords(size: UInt64) throws -> [String: String] {
        guard size <= Self.largestPaxHeader else { throw HangarError("The copy from the VM has an oversized header.") }
        let body = try take(Int(size))
        try skip(Tar.padding(after: size))

        var records: [String: String] = [:]
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " "), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(after: space)..<equals])
            // Only the name, size and date are read; xattrs and other records are never applied.
            if ["path", "size"].contains(key) { records[key] = String(line[line.index(after: equals)...]) }
        }
        if let path = records["path"], path.utf8.count > Self.longestName {
            throw HangarError("The copy from the VM has a name that is too long.")
        }
        return records
    }

    private mutating func longNameRecord(size: UInt64) throws -> String {
        guard size <= Self.longestName else { throw HangarError("The copy from the VM has a name that is too long.") }
        let bytes = try take(Int(size)).prefix { $0 != 0 }
        try skip(Tar.padding(after: size))
        return try Self.text(bytes)
    }

    private static func name(in header: ArraySlice<UInt8>) throws -> String {
        try text(header[Tar.nameField].prefix { $0 != 0 })
    }

    private static func text(_ bytes: some Collection<UInt8>) throws -> String {
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw HangarError("The copy from the VM has a name that isn't UTF-8.")
        }
        return text
    }

    private static func octal(_ field: ArraySlice<UInt8>) throws -> UInt64 {
        let digits = field.filter { $0 != 0 && $0 != 0x20 }
        guard let value = UInt64(String(decoding: digits, as: UTF8.self), radix: 8) ?? (digits.isEmpty ? 0 : nil) else {
            throw HangarError("The copy from the VM has a damaged header.")
        }
        return value
    }

    private static func decimal(_ text: String) throws -> UInt64 {
        guard let value = UInt64(text) else { throw HangarError("The copy from the VM has a damaged header.") }
        return value
    }

    /// Whether `count` bytes are there or the stream ended cleanly at a block boundary.
    private mutating func fill(_ count: Int) throws -> Bool {
        while buffer.count < count, !isAtEnd {
            guard let more = try source() else {
                isAtEnd = true
                break
            }
            buffer.append(more)
        }
        if buffer.count >= count { return true }
        guard buffer.isEmpty else { throw HangarError("The copy from the VM ended in the middle of a file.") }
        return false
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard try fill(count) else { throw HangarError("The copy from the VM ended in the middle of a file.") }
        let piece = Data(buffer.prefix(count))
        // removeFirst would keep the whole storage; the buffer holds a block and a frame, so a copy is small.
        buffer = Data(buffer.dropFirst(count))
        return piece
    }

    private mutating func skip(_ count: UInt64) throws {
        var left = count
        while left > 0 {
            let piece = try take(Int(min(left, UInt64(ExecFrame.maximumPayload))))
            left -= UInt64(piece.count)
        }
    }
}
