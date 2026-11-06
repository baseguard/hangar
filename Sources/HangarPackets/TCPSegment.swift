import Foundation

package struct TCPSegment {
    package static let fin: UInt8 = 0x01
    package static let syn: UInt8 = 0x02
    package static let rst: UInt8 = 0x04
    package static let ack: UInt8 = 0x10

    package let ip: IPv4Packet

    package init?(_ ip: IPv4Packet) {
        let start = ip.payloadOffset
        guard ip.protocolNumber == Packet.protocolTCP, !ip.isLaterFragment, ip.end >= start + 20 else { return nil }
        let headerLength = Int(ip.bytes[start + 12] >> 4) * 4
        guard headerLength >= 20, ip.end >= start + headerLength else { return nil }
        self.ip = ip
    }

    package var sourcePort: UInt16 { Packet.readUInt16(ip.bytes, at: ip.payloadOffset) }
    package var destinationPort: UInt16 { Packet.readUInt16(ip.bytes, at: ip.payloadOffset + 2) }
    package var sequence: UInt32 { Packet.readUInt32(ip.bytes, at: ip.payloadOffset + 4) }
    package var acknowledgment: UInt32 { Packet.readUInt32(ip.bytes, at: ip.payloadOffset + 8) }
    var flags: UInt8 { ip.bytes[ip.payloadOffset + 13] }
    package var payload: Range<Int> { (ip.payloadOffset + Int(ip.bytes[ip.payloadOffset + 12] >> 4) * 4)..<ip.end }

    package func has(_ flag: UInt8) -> Bool { flags & flag != 0 }
}
