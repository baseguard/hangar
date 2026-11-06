import Foundation
import Testing

@testable import HangarPackets

struct DHCPServerTests {
    private let subnet = IPv4Subnet(gateway: IPv4Address(10, 88, 0, 1), prefixLength: 24)
    private let macA: [UInt8] = [0x02, 0, 0, 0, 0, 0x0a]
    private let macB: [UInt8] = [0x02, 0, 0, 0, 0, 0x0b]

    private func server(reservations: [String: String] = [:], leases: [String: DHCPServer.Lease] = [:]) -> DHCPServer {
        var dhcp = DHCPServer(subnet: subnet, serverIP: subnet.serverAddress.value, leases: leases)
        dhcp.reservations = reservations.mapValues { ipv4($0) }
        return dhcp
    }

    private func request(type: UInt8, mac: [UInt8], requested: String? = nil, serverID: UInt32? = nil) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 240)
        bootp[0] = 1
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(28..<34, with: mac)
        bootp.replaceSubrange(236..<240, with: [99, 130, 83, 99])
        bootp += [53, 1, type]
        if let requested { bootp += [50, 4] + Packet.bytes(ipv4(requested).value) }
        if let serverID { bootp += [54, 4] + Packet.bytes(serverID) }
        return bootp + [255]
    }

    private func offered(_ reply: DHCPServer.Reply?) -> String? {
        reply.map { IPv4Address(Packet.readUInt32($0.payload, at: 16)).description }
    }

    @Test func reservedMACGetsItsReservation() {
        var dhcp = server(reservations: ["02:00:00:00:00:0a": "10.88.0.10"])

        #expect(offered(dhcp.handle(request(type: 1, mac: macA))) == "10.88.0.10")

        let ack = dhcp.handle(
            request(type: 3, mac: macA, requested: "10.88.0.10", serverID: subnet.serverAddress.value))

        #expect(ack?.payload[242] == 5)
        #expect(dhcp.leases["02:00:00:00:00:0a"]?.ip == IPv4Address("10.88.0.10"))
    }

    @Test func unreservedMACGetsAPoolAddressNeverTheServerOrGateway() throws {
        var dhcp = server()

        let address = try #require(offered(dhcp.handle(request(type: 1, mac: macB, requested: "10.88.0.2"))))

        #expect(subnet.dhcpPool.contains(try #require(IPv4Address(address)).value))
        #expect(address != "10.88.0.1")
        #expect(address != "10.88.0.2")
    }

    @Test func oldLeaseLosesToAnotherVMsReservation() {
        let lease = DHCPServer.Lease(ip: ipv4("10.88.0.12"), updatedAt: Date())
        var dhcp = server(reservations: ["02:00:00:00:00:0a": "10.88.0.12"], leases: ["02:00:00:00:00:0b": lease])

        let address = offered(dhcp.handle(request(type: 1, mac: macB)))
        let nak = dhcp.handle(
            request(type: 3, mac: macB, requested: "10.88.0.12", serverID: subnet.serverAddress.value))

        #expect(address != "10.88.0.12")
        #expect(nak?.payload[242] == 6)
    }

    @Test func declinedAddressIsNotOfferedAgain() throws {
        var dhcp = server()
        let first = try #require(offered(dhcp.handle(request(type: 1, mac: macB))))
        _ = dhcp.handle(request(type: 3, mac: macB, requested: first, serverID: subnet.serverAddress.value))

        #expect(dhcp.handle(request(type: 4, mac: macB, requested: first)) == nil)
        #expect(offered(dhcp.handle(request(type: 1, mac: macB))) != first)
    }

    @Test func clientsCanOnlyDeclineTheirOwnAddress() {
        var dhcp = server()

        for value in subnet.dhcpPool {
            _ = dhcp.handle(request(type: 4, mac: macA, requested: IPv4Address(value).description))
        }

        #expect(offered(dhcp.handle(request(type: 1, mac: macB))) != nil)
    }

    @Test func releaseRemovesTheLease() throws {
        var dhcp = server()
        let address = try #require(offered(dhcp.handle(request(type: 1, mac: macB))))
        _ = dhcp.handle(request(type: 3, mac: macB, requested: address, serverID: subnet.serverAddress.value))
        #expect(dhcp.leases["02:00:00:00:00:0b"] != nil)

        #expect(dhcp.handle(request(type: 7, mac: macB)) == nil)

        #expect(dhcp.leases["02:00:00:00:00:0b"] == nil)
    }

    @Test func oldLeasesArePruned() {
        let stale = DHCPServer.Lease(
            ip: ipv4("10.88.0.210"), updatedAt: Date(timeIntervalSinceNow: -30 * 86_400))

        let dhcp = server(leases: ["02:00:00:00:00:0b": stale])

        #expect(dhcp.leases["02:00:00:00:00:0b"] == nil)
    }

    @Test func shortOrForeignPacketsAreIgnored() {
        var dhcp = server()
        var wrongCookie = request(type: 1, mac: macB)
        wrongCookie[236] = 0

        #expect(dhcp.handle([1, 1, 6]) == nil)
        #expect(dhcp.handle(wrongCookie) == nil)
    }
}
