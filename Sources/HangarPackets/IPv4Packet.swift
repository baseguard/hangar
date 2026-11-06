import Foundation

package struct IPv4Packet {
    package let bytes: [UInt8]
    package let offset: Int

    package init?(_ bytes: [UInt8], offset: Int = 0) {
        guard bytes.count >= offset + 20, bytes[offset] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[offset] & 0x0f) * 4
        let total = Int(Packet.readUInt16(bytes, at: offset + 2))
        guard headerLength >= 20, total >= headerLength, bytes.count >= offset + total else { return nil }
        self.bytes = bytes
        self.offset = offset
    }

    package var headerLength: Int { Int(bytes[offset] & 0x0f) * 4 }
    package var totalLength: Int { Int(Packet.readUInt16(bytes, at: offset + 2)) }
    package var protocolNumber: UInt8 { bytes[offset + 9] }
    package var source: UInt32 { Packet.readUInt32(bytes, at: offset + 12) }
    package var destination: UInt32 { Packet.readUInt32(bytes, at: offset + 16) }
    package var payloadOffset: Int { offset + headerLength }
    package var end: Int { offset + totalLength }
    package var isLaterFragment: Bool { Packet.readUInt16(bytes, at: offset + 6) & 0x1fff != 0 }
}
