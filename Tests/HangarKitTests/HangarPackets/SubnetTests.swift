import Foundation
import HangarPackets
import Testing

struct SubnetTests {
    @Test func parsingRejectsUnusableSubnets() {
        #expect(IPv4Subnet("10.88.0.1/24") != nil)
        #expect(IPv4Subnet("10.88.0.0/24") == nil)
        #expect(IPv4Subnet("10.88.0.255/24") == nil)
        #expect(IPv4Subnet("10.88.0.1/30") == nil)
        #expect(IPv4Subnet("10.88.0.1/15") == nil)
        #expect(IPv4Subnet("10.88.0.1") == nil)
    }

    @Test func decodingAcceptsAValidSubnet() throws {
        let valid = Data(#"{"gateway":"10.88.0.1","prefixLength":24}"#.utf8)

        #expect(try JSONDecoder().decode(IPv4Subnet.self, from: valid).description == "10.88.0.1/24")
    }

    @Test(arguments: [
        #"{"gateway":"10.88.0.1","prefixLength":40}"#, #"{"gateway":"10.88.0.1","prefixLength":31}"#,
        #"{"gateway":"10.88.0.0","prefixLength":24}"#,
    ])
    func decodingRejectsAnUnusableSubnet(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(IPv4Subnet.self, from: Data(json.utf8)) }
    }

    @Test func serverAddressIsAHostAddress() throws {
        let lowGateway = try #require(IPv4Subnet("10.88.0.1/24"))
        let highGateway = try #require(IPv4Subnet("10.88.0.254/24"))
        let smallSubnet = try #require(IPv4Subnet("10.88.0.6/29"))

        #expect(lowGateway.serverAddress.description == "10.88.0.2")
        #expect(highGateway.serverAddress.description == "10.88.0.253")
        #expect(smallSubnet.serverAddress.description == "10.88.0.5")
    }

    @Test(arguments: [
        "10.88.0.1/24", "10.88.0.9/24", "10.88.0.230/24", "10.88.0.17/27", "10.88.0.1/28", "10.88.0.1/29",
        "10.88.0.6/29", "172.16.0.1/16",
    ])
    func rangesAreDisjointAndAvoidInfrastructure(_ text: String) throws {
        let subnet = try #require(IPv4Subnet(text))

        let pool = Set(subnet.dhcpPool)
        let reservable = Set(subnet.reservableRange)

        #expect(pool.isDisjoint(with: reservable))
        #expect(pool.allSatisfy { subnet.contains(IPv4Address($0)) })
        #expect(!pool.contains(subnet.broadcast.value))
        #expect(!reservable.contains(subnet.network.value))
        #expect(!reservable.subtracting(subnet.unavailableAddresses).isEmpty)
    }
}
