import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct GuestToolsTests {
    @Test func eachSystemGetsItsOwnTools() throws {
        let manager = FileManager.default
        let linux = try GuestTools.folder(for: .linux)
        #expect(try manager.contentsOfDirectory(atPath: linux.path) == [GuestTools.linuxAgent])
        let binary = linux.appendingPathComponent(GuestTools.linuxAgent)
        #expect(try Data(contentsOf: binary) == GuestFiles.data("linux/\(GuestTools.linuxAgent)"))
        #expect(try Data(contentsOf: binary).prefix(4) == Data([0x7f, 0x45, 0x4c, 0x46]))
        #expect(try manager.attributesOfItem(atPath: binary.path)[.posixPermissions] as? Int == 0o755)

        let mac = try GuestTools.folder(for: .macOS)
        #expect(try manager.contentsOfDirectory(atPath: mac.path) == [GuestTools.macAgent])
        let macAgent = mac.appendingPathComponent(GuestTools.macAgent)
        #expect(try Data(contentsOf: macAgent) == GuestFiles.data("macos/\(GuestTools.macAgent)"))
        #expect(try Data(contentsOf: macAgent).prefix(4) == Data([0xcf, 0xfa, 0xed, 0xfe]))
        #expect(try manager.attributesOfItem(atPath: macAgent.path)[.posixPermissions] as? Int == 0o755)

        let windows = try GuestTools.folder(for: .windows)
        #expect(try manager.contentsOfDirectory(atPath: windows.path) == [GuestTools.windowsAgent])
        #expect(GuestTools.windowsCommand == #"Z:\Tools\hangar-agent.exe"#)
        let installer = windows.appendingPathComponent(GuestTools.windowsAgent)
        #expect(try Data(contentsOf: installer) == GuestFiles.data("windows/\(GuestTools.windowsAgent)"))
        #expect(try Data(contentsOf: installer).prefix(2) == Data("MZ".utf8))
        #expect(try manager.attributesOfItem(atPath: installer.path)[.posixPermissions] as? Int == 0o755)
    }

    @Test func theLinuxCommandMountsTheSharesWithoutSetuidAndInstallsTheAgent() {
        #expect(
            GuestTools.linuxCommand
                == "sudo sh -ec 'mkdir -p /mnt/hangar; mountpoint -q /mnt/hangar || mount -t virtiofs -o nosuid,nodev hangar /mnt/hangar; /mnt/hangar/Tools/hangar-agent install'"
        )
    }

    @Test func staleToolsAreUpdatedInPlace() throws {
        let manager = FileManager.default
        let folder = try GuestTools.folder(for: .linux)
        let agent = folder.appendingPathComponent(GuestTools.linuxAgent)
        let identity = try manager.attributesOfItem(atPath: folder.path)[.systemFileNumber] as? Int

        try Data("changed".utf8).write(to: agent)
        try Data("old".utf8).write(to: folder.appendingPathComponent("old.sh"))
        _ = try GuestTools.folder(for: .linux)
        #expect(try Data(contentsOf: agent) == Data("changed".utf8))

        try Data("stale".utf8).write(to: GuestTools.root.appendingPathComponent(".stamp"))
        _ = try GuestTools.folder(for: .linux)
        #expect(try Data(contentsOf: agent) == GuestFiles.data("linux/\(GuestTools.linuxAgent)"))
        #expect(try manager.contentsOfDirectory(atPath: folder.path) == [GuestTools.linuxAgent])
        #expect(try manager.attributesOfItem(atPath: folder.path)[.systemFileNumber] as? Int == identity)
    }

    @Test func linkedToolsFoldersAreRefused() throws {
        let manager = FileManager.default
        let elsewhere = HangarPaths.home.appendingPathComponent("elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("keep"))
        try manager.createDirectory(at: HangarPaths.cache, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: GuestTools.root, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try GuestTools.folder(for: .linux) }
        #expect(try manager.contentsOfDirectory(atPath: elsewhere.path) == ["keep"])
    }
}
