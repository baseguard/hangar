import Foundation
import Testing

@testable import HangarPackets
@testable import HangarTraffic

struct DivertedConnectionsTests {
    private let guest = TCPRedirect.Endpoint(address: IPv4Address(10, 88, 0, 10).value, port: 50_000)
    private let destination = DivertedConnections.Destination(
        server: TCPRedirect.Endpoint(address: IPv4Address(140, 82, 121, 4).value, port: 443), names: ["api.github.com"])
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aConnectionIsTakenOnceAndOnlyWhileFresh() {
        let connections = DivertedConnections()
        #expect(connections.add(guest, to: destination, now: now))

        #expect(connections.take(guest, now: now.addingTimeInterval(1)) == destination)
        #expect(connections.take(guest, now: now.addingTimeInterval(2)) == nil)

        let late = TCPRedirect.Endpoint(address: guest.address, port: 50_001)
        #expect(connections.add(late, to: destination, now: now))
        #expect(connections.take(late, now: now.addingTimeInterval(DivertedConnections.acceptLimit + 1)) == nil)
    }

    @Test func pastTheLimitAConnectionIsntDiverted() {
        let connections = DivertedConnections()
        for port in 0..<DivertedConnections.limit {
            #expect(connections.add(TCPRedirect.Endpoint(address: 1, port: UInt16(port)), to: destination, now: now))
        }

        #expect(!connections.add(guest, to: destination, now: now))
    }
}
