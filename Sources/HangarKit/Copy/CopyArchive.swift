import Foundation
import HangarDisks
import HangarSupport

/// The tar stream `hangar cp` sends over `hangar exec`, laid out like `hangar_copy` in the guest agent; a change goes in
/// both. POSIX ustar with a PAX header for a name over 100 bytes or a size of 8 GiB or more, and only files and folders.
package enum CopyArchive {
    package enum Kind: Equatable, Sendable {
        case file(isExecutable: Bool)
        case folder
    }

    package struct Header: Equatable, Sendable {
        package let name: String
        package let kind: Kind
        package let size: UInt64
        package let modified: Date

        package init(name: String, kind: Kind, size: UInt64, modified: Date) {
            self.name = name
            self.kind = kind
            self.size = size
            self.modified = modified
        }
    }

    static let largestOctalSize: UInt64 = 1 << 33 - 1
    /// Two zero blocks end the archive.
    package static let end = Data(count: 2 * Tar.blockSize)

    /// The header's blocks, behind a PAX header when the name or size doesn't fit ustar's fields.
    package static func blocks(for header: Header) -> Data {
        let storedName = Array((header.kind == .folder ? header.name + "/" : header.name).utf8)
        let fitsSize = header.size <= largestOctalSize
        var records: [(String, String)] = []
        if storedName.count > Tar.nameField.count {
            records.append(("path", String(decoding: storedName, as: UTF8.self)))
        }
        if !fitsSize { records.append(("size", String(header.size))) }

        var blocks = Data()
        if !records.isEmpty { blocks.append(paxHeader(records)) }
        blocks.append(
            ustarHeader(
                name: Array(storedName.prefix(Tar.nameField.count)), type: header.kind == .folder ? "5" : "0",
                mode: mode(of: header.kind), size: fitsSize ? header.size : 0, modified: header.modified))
        return blocks
    }

    /// Splits a name into its parts and refuses any that could reach outside the copy or mislead in Finder.
    package static func components(of name: String) throws -> [String] {
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !name.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy(isAcceptable) else {
            throw HangarError("'\(printable(name))' isn't a name a copy can hold.")
        }
        return parts
    }

    /// Control characters and backslashes are shown as "?", so a name in an error can't hide what it is.
    static func printable(_ name: String) -> String {
        String(
            name.unicodeScalars.map { $0.properties.generalCategory == .control || $0 == "\\" ? "?" : Character($0) })
    }

    private static func isAcceptable(_ part: String) -> Bool {
        let hasOddCharacter = part.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0 == "\\" || $0 == "\u{0}"
        }
        return !part.isEmpty && part != "." && part != ".." && !hasOddCharacter
    }

    private static func ustarHeader(name: [UInt8], type: Character, mode: UInt64, size: UInt64, modified: Date) -> Data
    {
        var bytes = [UInt8](repeating: 0, count: Tar.blockSize)
        func put(_ field: [UInt8], at offset: Int) {
            bytes.replaceSubrange(offset..<offset + field.count, with: field)
        }

        put(name, at: Tar.nameField.lowerBound)
        put(octal(mode, digits: 7), at: Tar.modeField.lowerBound)
        put(octal(0, digits: 7), at: Tar.uidField.lowerBound)
        put(octal(0, digits: 7), at: Tar.gidField.lowerBound)
        put(octal(size, digits: 11), at: Tar.sizeField.lowerBound)
        put(octal(UInt64(max(0, modified.timeIntervalSince1970)), digits: 11), at: Tar.modifiedField.lowerBound)
        put(Array(String(type).utf8), at: Tar.typeField)
        put(Array("ustar".utf8), at: Tar.magicField.lowerBound)
        put(Array("00".utf8), at: Tar.versionField.lowerBound)
        put(Tar.checksumBytes(of: bytes), at: Tar.checksumField.lowerBound)
        return Data(bytes)
    }

    /// Each record is "<length> key=value\n", where the length counts the whole record, its own digits too.
    private static func paxHeader(_ records: [(String, String)]) -> Data {
        var body = Data()
        for (key, value) in records {
            let rest = " \(key)=\(value)\n"
            var length = rest.utf8.count + 1
            while String(length).count + rest.utf8.count != length { length += 1 }
            body.append(Data("\(length)\(rest)".utf8))
        }
        let header = ustarHeader(
            name: Array("PaxHeader".utf8), type: "x", mode: 0o644, size: UInt64(body.count), modified: .now)
        return header + body + Data(count: Tar.padding(after: body.count))
    }

    private static func mode(of kind: Kind) -> UInt64 {
        switch kind {
        case .folder, .file(isExecutable: true): 0o755
        case .file(isExecutable: false): 0o644
        }
    }

    private static func octal(_ value: UInt64, digits: Int) -> [UInt8] {
        let text = String(value, radix: 8)
        return Array((String(repeating: "0", count: max(0, digits - text.count)) + text).utf8)
    }
}
