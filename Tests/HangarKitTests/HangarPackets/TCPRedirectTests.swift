import Foundation
import Testing

@testable import HangarPackets

struct TCPRedirectTests {
    private let guest = IPv4Address(10, 88, 0, 10).value
    private let server = IPv4Address(140, 82, 121, 4).value

    private func segment(payload: [UInt8]) throws -> ([UInt8], TCPSegment) {
        let frame = Packet.ethernet(
            destination: [2, 0, 0, 0, 0, 1], source: [2, 0, 0, 0, 0, 2], type: Packet.etherTypeIPv4,
            payload: Packet.ipv4(
                source: guest, destination: server, protocol: Packet.protocolTCP,
                payload: Packet.tcp(
                    source: guest, destination: server, sourcePort: 50_000, destinationPort: 443, sequence: 1,
                    acknowledgment: 2, flags: TCPSegment.ack, payload: payload)))
        return (frame, try #require(IPv4Packet(frame, offset: 14).flatMap(TCPSegment.init)))
    }

    /// A checksum over data that carries its own correct checksum comes out zero.
    private func checksumsHold(_ tcp: TCPSegment) -> Bool {
        let ip = tcp.ip
        let header = ip.bytes[ip.offset..<ip.payloadOffset]
        let segment = ip.bytes[ip.payloadOffset..<ip.end]
        let pseudoHeader =
            Array(ip.bytes[(ip.offset + 12)..<(ip.offset + 20)])
            + [0, Packet.protocolTCP, UInt8(segment.count >> 8), UInt8(segment.count & 0xff)]
        return Packet.checksum(header) == 0 && Packet.checksum((pseudoHeader + segment)[...]) == 0
    }

    @Test func aMovedSegmentKeepsItsDataWithValidChecksums() throws {
        let (frame, tcp) = try segment(payload: Array("hello".utf8))
        let proxy = TCPRedirect.Endpoint(address: IPv4Address(10, 88, 0, 1).value, port: 61_000)

        let moved = TCPRedirect.destination(of: tcp, frame: frame, to: proxy)

        let movedTCP = try #require(IPv4Packet(moved, offset: 14).flatMap(TCPSegment.init))
        #expect(movedTCP.ip.destination == proxy.address)
        #expect(movedTCP.destinationPort == proxy.port)
        #expect(movedTCP.ip.source == guest)
        #expect(Array(movedTCP.ip.bytes[movedTCP.payload]) == Array("hello".utf8))
        #expect(checksumsHold(movedTCP))
    }

    @Test func anOddLengthSegmentMovesBackAsTheServer() throws {
        let (frame, tcp) = try segment(payload: Array("odd".utf8))
        let other = TCPRedirect.Endpoint(address: IPv4Address(1, 2, 3, 4).value, port: 8443)

        let moved = TCPRedirect.source(of: tcp, frame: frame, to: other)

        let movedTCP = try #require(IPv4Packet(moved, offset: 14).flatMap(TCPSegment.init))
        #expect(movedTCP.ip.source == other.address)
        #expect(movedTCP.sourcePort == other.port)
        #expect(checksumsHold(movedTCP))
    }
}
