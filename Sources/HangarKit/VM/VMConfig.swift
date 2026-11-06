import Foundation
import HangarSecrets
import HangarSupport
import HangarTraffic
import Virtualization

package struct VMConfig: Codable, Hashable, Sendable {
    package var os: GuestOS
    package var cpuCount: Int
    package var memorySize: UInt64
    package var display: DisplaySettings
    package var network: NetworkSettings
    package var sharedFolders: [SharedFolder] = []
    package var isoPath: String?
    package var rosetta = false
    /// Lets the guest run its own VMs. Configs saved before this setting existed leave it out, which means off.
    package var nested: Bool?
    package var audio = true
    package var clipboard = false
    package var remoteDesktop = true
    package var hardwareModel: Data?
    package var machineIdentifier: Data?
    package var provisioning: MacProvisioning?
    package var sshUser: String?
    package var image: String?
    /// What it was made from, for a template saved from it; `nil` for a VM made before Hangar kept it.
    package var origin: VMTemplate.Origin?
    /// The cloud-init settings it was made with, for a template saved from it.
    package var cloudInit: String?
    /// Commands Hangar runs through the agent once the VM has started for the first time.
    package var setup: [String]?
    /// When the setup commands ran, whether or not they all worked; they never run twice by themselves.
    package var setupRanAt: Date?
    package var firstStartedAt: Date?
    package var autoStart = false
    package var traffic = TrafficPolicy()
    package var secrets: SecretSettings?
    package var createdAt = Date()

    package init(os: GuestOS, cpuCount: Int, memorySize: UInt64, display: DisplaySettings, network: NetworkSettings) {
        self.os = os
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.display = display
        self.network = network
    }

    /// Every stored setting, as config.json names it.
    static let keys: Set<String> = [
        "os", "cpuCount", "memorySize", "display", "network", "sharedFolders", "isoPath", "rosetta", "nested", "audio",
        "clipboard", "remoteDesktop", "hardwareModel", "machineIdentifier", "provisioning", "sshUser", "image",
        "origin", "cloudInit", "setup", "setupRanAt", "firstStartedAt", "autoStart", "traffic", "secrets", "createdAt",
    ]

    /// Reads a VM's or a snapshot's config.json, refusing fields Hangar doesn't know, so a misspelled one isn't
    /// silently dropped.
    static func read(from url: URL) throws -> VMConfig {
        let data = try Data(contentsOf: url)
        if let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            try JSON.refuseUnknownKeys(in: fields, known: keys, of: url.path)
        }
        return try JSON.decoder.decode(VMConfig.self, from: data)
    }

    package var guestDisplay: DisplaySettings {
        os == .windows ? WindowsPlatform.display : display
    }

    package var usesNestedVirtualization: Bool {
        get { nested == true }
        set { nested = newValue }
    }

    package var followsWindowSize: Bool {
        os != .windows
    }

    package static func randomMACAddress() -> String {
        VZMACAddress.randomLocallyAdministered().string
    }

    static func newMachineIdentifier(for os: GuestOS) -> Data {
        switch os {
        case .macOS: VZMacMachineIdentifier().dataRepresentation
        case .linux, .windows: VZGenericMachineIdentifier().dataRepresentation
        }
    }

    /// The account Hangar makes when none is asked for, on every OS.
    package static let defaultUser = "admin"

    package var loginUser: String { sshUser ?? Self.defaultUser }

    package static func isValidUserName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]{0,31}/) != nil
    }

    package static func validate(userName: String) throws {
        guard isValidUserName(userName) else {
            throw HangarError(
                "'\(userName)' can't be a user name: up to 32 letters, digits, '.', '_' or '-', not starting with '-'.")
        }
    }
}
