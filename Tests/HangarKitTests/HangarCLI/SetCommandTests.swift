import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

/// `hangar set` and Hangar.app share VMSettings; these check that the command line goes through it.
@Suite(.temporaryHangarHome)
struct SetCommandTests {
    private func makeVM(_ name: String, os: GuestOS) async throws -> VMBundle {
        let network = NetworkSettings(mode: .nat, macAddress: VMConfig.randomMACAddress())
        let config = VMConfig(
            os: os, cpuCount: 2, memorySize: 2 * ByteSize.gib, display: .linuxDefault, network: network)
        return try await VMLibrary.create(name: name) { staging in
            try SparseFile.create(at: staging.diskURL, size: 1 << 20)
            try staging.saveConfig(config)
        }
    }

    @Test func aRunningVMTakesTheDefaultUserButNotNewHardware() async throws {
        let bundle = try await makeVM("busy", os: .linux)
        let runLock = FileLock(url: bundle.lockURL)
        try runLock.lock(.exclusive)

        let user = try HangarCommand.run(["set", "busy", "--ssh-user", "dev", "--autostart", "on"])
        let hardware = try HangarCommand.run(["set", "busy", "--cpu", "1"])

        #expect(user.status == 0)
        #expect(try bundle.loadConfig().sshUser == "dev")
        #expect(hardware.status == 1)
        #expect(hardware.error == "Error: 'busy' is running. Stop it first.\n")
        // Holds the run lock, and so the VM's running state, until both commands have run.
        runLock.unlock()
    }

    @Test func aRefusedDiskSizeChangesNothing() async throws {
        let bundle = try await makeVM("box", os: .linux)
        try SparseFile.create(at: bundle.diskURL, size: 2 * ByteSize.gib, truncateExisting: true)

        let result = try HangarCommand.run(["set", "box", "--cpu", "1", "--disk", "1"])

        #expect(result.status == 1)
        #expect(result.error == "Error: Disks can only grow (current size 2 GB).\n")
        #expect(try bundle.loadConfig().cpuCount == 2)
    }
}
