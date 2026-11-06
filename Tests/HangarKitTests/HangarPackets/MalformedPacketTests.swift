import Foundation
import Testing

@testable import HangarPackets

/// What a guest can put on the wire: each header field that says how long something is, set to a lie.
struct MalformedPacketTests {
    private let source = IPv4Address(10, 0, 0, 2).value
    private let destination = IPv4Address(10, 0, 0, 1).value

    private func udpPacket() -> [UInt8] {
        Packet.ipv4(
            source: source, destination: destination, protocol: Packet.protocolUDP,
            payload: Packet.udp(sourcePort: 5000, destinationPort: 53, payload: [1, 2, 3, 4]))
    }

    private func tcpPacket() -> [UInt8] {
        Packet.ipv4(
            source: source, destination: destination, protocol: Packet.protocolTCP,
            payload: Packet.tcp(
                source: source, destination: destination, sourcePort: 5000, destinationPort: 443, sequence: 1,
                acknowledgment: 0, flags: TCPSegment.syn))
    }

    @Test(arguments: [
        ("version 6", 0, 0x65 as UInt8),
        ("a 16-byte header", 0, 0x44),
        ("a total length shorter than the header", 3, 19),
    ])
    func anIPv4HeaderThatLiesIsRefused(lie: String, byte: Int, value: UInt8) {
        var packet = udpPacket()
        packet[byte] = value

        #expect(IPv4Packet(packet) == nil)
    }

    @Test func anIPv4PacketLongerThanItsBytesIsRefused() {
        var packet = udpPacket()
        packet[3] = UInt8(packet.count + 1)

        #expect(IPv4Packet(packet) == nil)
    }

    @Test(arguments: [
        ("a 16-byte TCP header", 32, 0x40 as UInt8),
        ("a 60-byte header in a 20-byte segment", 32, 0xf0),
        ("a later fragment, which has no ports", 7, 0x10),
    ])
    func aTCPHeaderThatLiesIsRefused(lie: String, byte: Int, value: UInt8) throws {
        var packet = tcpPacket()
        packet[byte] = value
        let ip = try #require(IPv4Packet(packet))

        #expect(TCPSegment(ip) == nil)
    }

    @Test func aUDPDatagramShorterThanItsHeaderIsRefused() throws {
        let packet = Packet.ipv4(
            source: source, destination: destination, protocol: Packet.protocolUDP, payload: [0, 53, 0, 53])
        let ip = try #require(IPv4Packet(packet))

        #expect(UDPDatagram(ip) == nil)
    }

    @Test(arguments: [("a length shorter than the header", 7), ("a length past the packet", 13)])
    func aUDPLengthThatLiesIsRefused(lie: String, length: Int) throws {
        var packet = udpPacket()
        packet[25] = UInt8(length)
        let ip = try #require(IPv4Packet(packet))

        #expect(UDPDatagram(ip) == nil)
    }

    @Test func bytesAfterTheUDPLengthAreNotPayload() throws {
        let datagram = Packet.udp(sourcePort: 5000, destinationPort: 53, payload: [1, 2, 3, 4]) + [9, 9, 9]
        let packet = Packet.ipv4(
            source: source, destination: destination, protocol: Packet.protocolUDP, payload: datagram)
        let udp = try #require(IPv4Packet(packet).flatMap(UDPDatagram.init))

        #expect(Array(packet[udp.payload]) == [1, 2, 3, 4])
    }

    private static let dnsNameLies: [(String, [UInt8])] = [
        ("a 64-byte label", [64] + [UInt8](repeating: 0x61, count: 64) + [0]),
        ("a pointer to itself", [0xc0, 12]),
        (
            "a 320-byte name",
            Array(repeating: [63] + [UInt8](repeating: 0x61, count: 63), count: 5).flatMap { $0 } + [0]
        ),
        ("a label past the end", [3, 0x61, 0x62]),
    ]

    @Test(arguments: dnsNameLies)
    func aDNSNameThatLiesIsRefused(lie: String, name: [UInt8]) {
        let query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + name + [0, 1, 0, 1]

        #expect(DNSMessage(query) == nil)
    }

    @Test func aDNSAnswerWhoseDataRunsPastTheEndIsDropped() throws {
        let question: [UInt8] = [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        let header: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        let answer: [UInt8] = [0xc0, 12, 0, 1, 0, 1, 0, 0, 0x0e, 0x10, 0x01, 0x00, 93, 184, 216, 34]

        let message = try #require(DNSMessage(header + question + answer))

        #expect(message.answers.isEmpty)
    }

    @Test func aDHCPOptionLongerThanThePacketCarriesNoMessageType() {
        var server = DHCPServer(
            subnet: IPv4Subnet(gateway: IPv4Address(10, 0, 0, 1), prefixLength: 24), serverIP: destination,
            leases: [:])
        var discover = [UInt8](repeating: 0, count: 240)
        discover[0] = 1
        discover[1] = 1
        discover[2] = 6
        discover.replaceSubrange(28..<34, with: [0x02, 0, 0, 0, 0, 0x10])
        discover.replaceSubrange(236..<240, with: [99, 130, 83, 99])

        let reply = server.handle(discover + [53, 200, 1])

        #expect(reply == nil)
    }
}
