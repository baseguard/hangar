import Foundation

package enum Packet {
    package static let etherTypeIPv4: UInt16 = 0x0800
    package static let etherTypeARP: UInt16 = 0x0806
    package static let protocolICMP: UInt8 = 1
    package static let protocolIGMP: UInt8 = 2
    package static let protocolTCP: UInt8 = 6
    package static let protocolUDP: UInt8 = 17
    package static let broadcastMAC: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    package static let zeroMAC: [UInt8] = [0, 0, 0, 0, 0, 0]
    package static let destinationMAC = 0..<6
    package static let sourceMAC = 6..<12
    package static let ethernetHeaderLength = 14
    package static let ipv4HeaderLength = 20
    package static let udpHeaderLength = 8
    /// Ethernet's shortest and longest frames; vmnet needs shorter ones padded.
    package static let shortestFrame = 60
    package static let longestFrame = 1514
    package static let dnsPort: UInt16 = 53
    package static let httpsPort: UInt16 = 443

    /// What the packets Hangar builds itself carry: a long enough life, no fragmenting, no TCP options and the
    /// widest window.
    private static let timeToLive: UInt8 = 64
    private static let dontFragment: UInt8 = 0x40
    private static let ipv4ChecksumOffset = 10
    private static let tcpHeaderOfFiveWords: UInt8 = 0x50
    private static let tcpWindow: [UInt8] = [0xff, 0xff]
    private static let tcpChecksumOffset = 16

    /// Bytes as text a terminal shows as they are: anything but printable ASCII becomes `?`.
    package static func printable(_ bytes: some Sequence<UInt8>) -> String {
        String(decoding: bytes.map { (0x21...0x7e).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    package static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    package static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    package static func writeUInt16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }

    static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(value >> (24 - 8 * UInt32(i)) & 0xff) }
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    package static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        foldedChecksum(onesComplementSum(bytes))
    }

    /// The 16-bit words of `bytes` added up, the last byte padded with zero; parts of even length add up to the sum
    /// of the whole.
    static func onesComplementSum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var sum: UInt32 = 0
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.endIndex { sum += UInt32(bytes[index]) << 8 }
        return sum
    }

    static func foldedChecksum(_ sum: UInt32) -> UInt16 {
        var folded = sum
        while folded >> 16 != 0 { folded = (folded & 0xffff) + (folded >> 16) }
        return ~UInt16(folded)
    }

    package static func ethernet(destination: [UInt8], source: [UInt8], type: UInt16, payload: [UInt8]) -> [UInt8] {
        destination + source + [UInt8(type >> 8), UInt8(type & 0xff)] + payload
    }

    package static func arp(
        operation: UInt16, senderMAC: [UInt8], senderIP: UInt32, targetMAC: [UInt8], targetIP: UInt32
    )
        -> [UInt8]
    {
        [0, 1, 8, 0, 6, 4, UInt8(operation >> 8), UInt8(operation & 0xff)]
            + senderMAC + bytes(senderIP) + targetMAC + bytes(targetIP)
    }

    package static func ipv4(source: UInt32, destination: UInt32, protocol protocolNumber: UInt8, payload: [UInt8])
        -> [UInt8]
    {
        let length = ipv4HeaderLength + payload.count
        var header: [UInt8] = [
            0x45, 0, UInt8(length >> 8), UInt8(length & 0xff), 0, 0, dontFragment, 0, timeToLive, protocolNumber, 0, 0,
        ]
        header += bytes(source) + bytes(destination)
        writeUInt16(checksum(header[...]), into: &header, at: ipv4ChecksumOffset)
        return header + payload
    }

    package static func udp(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) -> [UInt8] {
        let length = udpHeaderLength + payload.count
        return [
            UInt8(sourcePort >> 8), UInt8(sourcePort & 0xff), UInt8(destinationPort >> 8),
            UInt8(destinationPort & 0xff),
            UInt8(length >> 8), UInt8(length & 0xff), 0, 0,
        ] + payload
    }

    package static func tcp(
        source: UInt32, destination: UInt32, sourcePort: UInt16, destinationPort: UInt16,
        sequence: UInt32, acknowledgment: UInt32, flags: UInt8, payload: [UInt8] = []
    ) -> [UInt8] {
        var segment: [UInt8] = [
            UInt8(sourcePort >> 8), UInt8(sourcePort & 0xff), UInt8(destinationPort >> 8),
            UInt8(destinationPort & 0xff),
        ]
        segment += bytes(sequence) + bytes(acknowledgment) + [tcpHeaderOfFiveWords, flags] + tcpWindow + [0, 0, 0, 0]
        segment += payload
        let pseudoHeader =
            bytes(source) + bytes(destination) + [
                0, protocolTCP, UInt8(segment.count >> 8), UInt8(segment.count & 0xff),
            ]
        writeUInt16(checksum((pseudoHeader + segment)[...]), into: &segment, at: tcpChecksumOffset)
        return segment
    }
}
