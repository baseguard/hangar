import Foundation

package struct UDPDatagram {
    package let ip: IPv4Packet
    /// From the UDP header, which receivers go by: they cut what follows and drop a datagram that claims more
    /// than the packet carries, so nothing past it may be parsed here either.
    package let length: Int

    package init?(_ ip: IPv4Packet) {
        guard ip.protocolNumber == Packet.protocolUDP, !ip.isLaterFragment, ip.end >= ip.payloadOffset + 8 else {
            return nil
        }
        let length = Int(Packet.readUInt16(ip.bytes, at: ip.payloadOffset + 4))
        guard length >= 8, ip.payloadOffset + length <= ip.end else { return nil }
        self.ip = ip
        self.length = length
    }

    package var sourcePort: UInt16 { Packet.readUInt16(ip.bytes, at: ip.payloadOffset) }
    package var destinationPort: UInt16 { Packet.readUInt16(ip.bytes, at: ip.payloadOffset + 2) }
    package var payload: Range<Int> { (ip.payloadOffset + 8)..<(ip.payloadOffset + length) }
}
