import Foundation
import HangarSupport
import Testing

@testable import HangarKit
@testable import HangarPackets

@Suite(.temporaryHangarHome)
struct IPResolverTests {
    @Test func oldLeasesAreIgnoredAfterARestartUnlessTheyMatchTheReservation() throws {
        try FileManager.default.createDirectory(at: HangarPaths.network, withIntermediateDirectories: true)
        let mac = "02:00:00:00:00:0a"
        let old = DHCPServer.Lease(
            ip: ipv4("10.88.0.205"), updatedAt: Date(timeIntervalSinceNow: -600))
        try JSON.write([mac: old], to: DHCPService.leasesURL)

        #expect(IPResolver.currentLease(for: mac, reserved: "10.88.0.12", startedAt: nil) == "10.88.0.205")
        #expect(
            IPResolver.currentLease(for: mac, reserved: "10.88.0.12", startedAt: Date(timeIntervalSinceNow: -60)) == nil
        )
        #expect(
            IPResolver.currentLease(for: mac, reserved: "10.88.0.205", startedAt: Date(timeIntervalSinceNow: -60))
                == "10.88.0.205")
        #expect(
            IPResolver.currentLease(for: mac, reserved: "10.88.0.12", startedAt: Date(timeIntervalSinceNow: -900))
                == "10.88.0.205")
    }

    @Test func arpTablesAreReadFromRoutingMessages() {
        var message = [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)
        var inet = [UInt8](repeating: 0, count: 16)
        inet[0] = 16
        inet[1] = UInt8(AF_INET)
        inet.replaceSubrange(4..<8, with: [10, 88, 0, 12])
        var link = [UInt8](repeating: 0, count: 20)
        link[0] = 20
        link[1] = UInt8(AF_LINK)
        link[5] = 3
        link[6] = 6
        link.replaceSubrange(8..<11, with: Array("en0".utf8))
        link.replaceSubrange(11..<17, with: [0x06, 0x7d, 0x2a, 0xbc, 0x1a, 0x59])
        message += inet + link
        message[0] = UInt8(message.count & 0xFF)
        message[1] = UInt8(message.count >> 8)

        let entries = IPResolver.entries(inRoutingMessages: message + message)

        #expect(entries.count == 2)
        #expect(entries.first?.ip == "10.88.0.12")
        #expect(entries.first?.mac == "06:7d:2a:bc:1a:59")
        #expect(IPResolver.entries(inRoutingMessages: Array(message.prefix(40))).isEmpty)
    }
}
