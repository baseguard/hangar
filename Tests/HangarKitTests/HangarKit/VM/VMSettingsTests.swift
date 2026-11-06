import Foundation
import HangarDisks
import HangarSupport
import HangarTraffic
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct VMSettingsTests {
    private func config(_ os: GuestOS, network: NetworkMode = .nat) -> VMConfig {
        VMConfig(
            os: os, cpuCount: 2, memorySize: 2 * ByteSize.gib, display: .linuxDefault,
            network: NetworkSettings(mode: network, macAddress: VMConfig.randomMACAddress()))
    }

    private func makeVM(_ name: String, network: NetworkMode = .nat) async throws -> VMBundle {
        let settings = config(.linux, network: network)
        return try await VMLibrary.create(name: name) { staging in
            try SparseFile.create(at: staging.diskURL, size: 1 << 20)
            try staging.saveConfig(settings)
        }
    }

    @Test func onlyWhatChangedIsChecked() throws {
        var fromALargerMac = config(.linux)
        fromALargerMac.memorySize = VMSettings.largestMemory + ByteSize.gib
        var autostarting = fromALargerMac
        autostarting.autoStart = true
        var larger = fromALargerMac
        larger.memorySize += ByteSize.gib

        try VMSettings.check(from: fromALargerMac, to: autostarting)

        #expect(throws: HangarError.self) { try VMSettings.check(from: fromALargerMac, to: larger) }
    }

    @Test func windowsKeepsItsScreenSize() throws {
        let windows = config(.windows)
        var resized = windows
        resized.display.width = 2560
        var morePowerful = windows
        morePowerful.cpuCount = 1

        try VMSettings.check(from: windows, to: morePowerful)

        #expect(throws: HangarError.self) { try VMSettings.check(from: windows, to: resized) }
    }

    @Test func devicesTheGuestCantUseAreRefused() {
        let macOS = config(.macOS)
        var rosetta = macOS
        rosetta.rosetta = true
        var windows = config(.windows)
        windows.audio = false
        var withISO = windows
        withISO.isoPath = "/tmp/linux.iso"
        var withAudio = windows
        withAudio.audio = true
        var nested = macOS
        nested.usesNestedVirtualization = true

        #expect(throws: HangarError.self) { try VMSettings.check(from: macOS, to: rosetta) }
        #expect(throws: HangarError.self) { try VMSettings.check(from: macOS, to: nested) }
        #expect(throws: HangarError.self) { try VMSettings.check(from: windows, to: withISO) }
        #expect(throws: HangarError.self) { try VMSettings.check(from: windows, to: withAudio) }
    }

    @Test func aDefaultUserMustBeAUserName() {
        let linux = config(.linux)
        var renamed = linux
        renamed.sshUser = "-rf"

        #expect(throws: HangarError.self) { try VMSettings.check(from: linux, to: renamed) }
    }

    @Test func trafficRulesKeepTheVMOnHangarsNetwork() {
        var guarded = config(.linux, network: .managed)
        guarded.traffic = TrafficPolicy(mode: .allowlist, allowed: ["github.com"])
        var onNAT = guarded
        onNAT.network.mode = .nat

        #expect(throws: HangarError.self) { try VMSettings.check(from: guarded, to: onNAT) }
    }

    @Test func aRunningVMTakesOnlyLiveChanges() async throws {
        let bundle = try await makeVM("busy")
        let runLock = FileLock(url: bundle.lockURL)
        try runLock.lock(.exclusive)

        let autostarting = try VMSettings.change(bundle) { $0.autoStart = true }
        let attached = try VMSettings.change(bundle, appliedLive: true) { $0.isoPath = "/tmp/linux.iso" }

        #expect(throws: HangarError.self) { try VMSettings.change(bundle) { $0.cpuCount = 1 } }
        #expect(autostarting.autoStart)
        #expect(attached.isoPath == "/tmp/linux.iso")
        #expect(try bundle.loadConfig().cpuCount == 2)
        // Holds the run lock, and so the VM's running state, until the checks have run.
        runLock.unlock()
    }

    @Test func movingToHangarsNetworkReservesAnAddress() async throws {
        let bundle = try await makeVM("moved")

        let moved = try VMSettings.change(bundle) { $0.network.mode = .managed }

        #expect(moved.network.ipAddress != nil)
        #expect(try bundle.loadConfig().network.ipAddress == moved.network.ipAddress)
    }
}
