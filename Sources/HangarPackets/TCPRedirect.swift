import Foundation

/// Moves a TCP segment, inside its Ethernet frame, to another address and port, with both checksums written again. It
/// lets the guest's connection to a server end at a proxy on the host, and the proxy's answers look like the server's.
package enum TCPRedirect {
    package struct Endpoint: Equatable, Hashable, Sendable {
        package let address: UInt32
        package let port: UInt16

        package init(address: UInt32, port: UInt16) {
            self.address = address
            self.port = port
        }
    }

    /// The frame sent to `destination` instead.
    package static func destination(of tcp: TCPSegment, frame: [UInt8], to destination: Endpoint) -> [UInt8] {
        rewrite(tcp, frame: frame, addressOffset: 16, portOffset: 2, to: destination)
    }

    /// The frame coming from `source` instead.
    package static func source(of tcp: TCPSegment, frame: [UInt8], to source: Endpoint) -> [UInt8] {
        rewrite(tcp, frame: frame, addressOffset: 12, portOffset: 0, to: source)
    }

    private static func rewrite(
        _ tcp: TCPSegment, frame: [UInt8], addressOffset: Int, portOffset: Int, to endpoint: Endpoint
    ) -> [UInt8] {
        let ip = tcp.ip
        var bytes = Array(frame[..<ip.end])
        Packet.writeUInt32(endpoint.address, into: &bytes, at: ip.offset + addressOffset)
        Packet.writeUInt16(endpoint.port, into: &bytes, at: ip.payloadOffset + portOffset)
        writeIPChecksum(into: &bytes, ip: ip)
        writeTCPChecksum(into: &bytes, ip: ip)
        return bytes
    }

    private static func writeIPChecksum(into bytes: inout [UInt8], ip: IPv4Packet) {
        let checksumOffset = ip.offset + 10
        Packet.writeUInt16(0, into: &bytes, at: checksumOffset)
        let header = bytes[ip.offset..<ip.payloadOffset]
        Packet.writeUInt16(Packet.checksum(header), into: &bytes, at: checksumOffset)
    }

    private static func writeTCPChecksum(into bytes: inout [UInt8], ip: IPv4Packet) {
        let checksumOffset = ip.payloadOffset + 16
        Packet.writeUInt16(0, into: &bytes, at: checksumOffset)
        let length = ip.end - ip.payloadOffset
        let pseudoHeader =
            Array(bytes[(ip.offset + 12)..<(ip.offset + 20)]) + [
                0, Packet.protocolTCP, UInt8(length >> 8), UInt8(length & 0xff),
            ]
        // Both parts have even lengths up to the segment's end, so their sums add up without copying the segment.
        let sum =
            Packet.onesComplementSum(pseudoHeader[...]) + Packet.onesComplementSum(bytes[ip.payloadOffset..<ip.end])
        Packet.writeUInt16(Packet.foldedChecksum(sum), into: &bytes, at: checksumOffset)
    }
}
