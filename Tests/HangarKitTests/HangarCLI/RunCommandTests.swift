import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct RunCommandTests {
    private func makeVM(_ name: String, os: GuestOS) async throws -> VMBundle {
        let network = NetworkSettings(mode: .nat, macAddress: VMConfig.randomMACAddress())
        let config = VMConfig(
            os: os, cpuCount: 2, memorySize: 2 * ByteSize.gib, display: .linuxDefault, network: network)
        return try await VMLibrary.create(name: name) { staging in
            try SparseFile.create(at: staging.diskURL, size: 1 << 20)
            try staging.saveConfig(config)
        }
    }

    @Test func anISOIsRefusedOnlyWhereTheGuestCantReadIt() async throws {
        _ = try await makeVM("win", os: .windows)

        let result = try HangarCommand.run(["run", "win", "--iso", "linux.iso"])

        #expect(result.status == 1)
        #expect(
            result.error
                == "Error: Windows can't read ISOs here: it needs a CD drive, which virtual machines on this Mac don't have.\n"
        )
    }

    @Test func aVMWithoutItsDiskSaysSo() async throws {
        let bundle = try await makeVM("box", os: .linux)
        try FileManager.default.removeItem(at: bundle.diskURL)

        let result = try HangarCommand.run(["run", "box", "--no-graphics"])

        #expect(result.status == 1)
        #expect(result.error == "Error: 'box' can't start: its disk \(bundle.diskURL.path) is missing.\n")
    }
}
