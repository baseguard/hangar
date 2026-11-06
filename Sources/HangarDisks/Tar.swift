/// The ustar header layout shared by Hangar's image files and its copies, in HangarKit.
package enum Tar {
    package static let blockSize = 512

    /// The header's fields, by byte offset.
    package static let nameField = 0..<100
    package static let modeField = 100..<108
    package static let uidField = 108..<116
    package static let gidField = 116..<124
    package static let sizeField = 124..<136
    package static let modifiedField = 136..<148
    package static let checksumField = 148..<156
    package static let typeField = 156
    package static let magicField = 257..<263
    package static let versionField = 263..<265
    package static let prefixField = 345..<500

    package static func padding<Size: BinaryInteger>(after size: Size) -> Size {
        let block = Size(blockSize)
        return (block - size % block) % block
    }

    /// The sum of the header's bytes with its own checksum field counted as spaces.
    package static func checksum(of header: [UInt8]) -> Int {
        var sum = 0
        for (index, byte) in header.enumerated() {
            sum += checksumField.contains(index) ? 0x20 : Int(byte)
        }
        return sum
    }

    /// The checksum as the field carries it: six octal digits, a NUL and a space.
    package static func checksumBytes(of header: [UInt8]) -> [UInt8] {
        let digits = String(checksum(of: header), radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        return Array(padded.utf8) + [0, UInt8(ascii: " ")]
    }
}
