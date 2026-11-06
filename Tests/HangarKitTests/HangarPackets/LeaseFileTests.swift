import Foundation
import HangarPackets
import HangarSupport
import Testing

struct LeaseFileTests {
    @Test func leaseFilesKeepTheirFormat() throws {
        let json = #"""
            {
              "4e:7e:4f:46:d3:c5" : {
                "ip" : "10.88.0.12",
                "updatedAt" : "2026-10-25T22:52:04Z"
              }
            }
            """#

        let leases = try JSON.decoder.decode([String: DHCPServer.Lease].self, from: Data(json.utf8))

        #expect(leases["4e:7e:4f:46:d3:c5"]?.ip == IPv4Address("10.88.0.12"))
        #expect(String(decoding: try JSON.encoder.encode(leases), as: UTF8.self) == json)
    }
}
