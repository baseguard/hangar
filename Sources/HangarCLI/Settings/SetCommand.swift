import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change a VM's settings.",
        discussion: """
            Examples:
              hangar set deb --cpu 4 --memory 8
                  Give deb 4 processors and 8 GB of memory.
              hangar set deb --disk 60
                  Grow deb's disk to 60 GB.
              hangar set deb --clipboard on --audio on
                  Share the clipboard and play the VM's sound on this Mac.
              hangar set deb --autostart on
                  Start deb whenever Hangar.app opens.

            Shut the VM down first; only --autostart and --ssh-user change while it runs.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @OptionGroup(title: "Hardware")
    var hardware: HardwareOptions

    @OptionGroup(title: "Devices")
    var devices: DeviceOptions

    @OptionGroup(title: "Network")
    var networking: NetworkOptions

    @OptionGroup(title: "Other")
    var other: OtherOptions

    struct HardwareOptions: ParsableArguments {
        @Option(help: ArgumentHelp("Processors.", valueName: "count"))
        var cpu: Int?

        @Option(help: ArgumentHelp("Memory in GB.", valueName: "gb"))
        var memory: Int?

        @Option(help: ArgumentHelp("Grow the disk to this many GB; it can't shrink.", valueName: "gb"))
        var disk: Int?

        @Option(help: ArgumentHelp("Screen size, e.g. 1920x1080. Not for Windows.", valueName: "size"))
        var display: String?
    }

    struct DeviceOptions: ParsableArguments {
        @Option(help: ArgumentHelp("Attach an ISO as a USB drive. macOS and Linux.", valueName: "file"))
        var iso: String?

        @Flag(help: "Detach the ISO.")
        var noIso = false

        @Option(
            help: ArgumentHelp("Share the clipboard with the VM, through Hangar's agent in it.", valueName: "on|off"))
        var clipboard: OnOff?

        @Option(help: ArgumentHelp("Play the VM's sound on this Mac. macOS and Linux.", valueName: "on|off"))
        var audio: OnOff?

        @Option(help: ArgumentHelp("Run Intel (x86-64) programs with Rosetta. Linux.", valueName: "on|off"))
        var rosetta: OnOff?

        @Option(
            help: ArgumentHelp(
                "Let the VM run its own VMs. Linux and Windows, on an M3 or later.", valueName: "on|off"))
        var nested: OnOff?
    }

    struct NetworkOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "managed: Hangar's network, with traffic rules. nat: the system's NAT, without traffic rules. none: no network.",
                valueName: "managed|nat|none"))
        var network: NetworkMode?

        @Flag(help: "Give the VM a new random MAC address.")
        var newMac = false
    }

    struct OtherOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "The user that Hangar.app's SSH button and Remote Desktop sign in as.", valueName: "name"))
        var sshUser: String?

        @Option(
            help: ArgumentHelp(
                "Start the VM in the background whenever Hangar.app opens.", valueName: "on|off")
        )
        var autostart: OnOff?
    }

    // Checked here rather than in run() so a mistake prints `hangar set`'s usage, not the root command's.
    func validate() throws {
        guard changesSomething else { throw ValidationError("Give a setting to change, like --cpu 4.") }
        guard devices.iso == nil || !devices.noIso else {
            throw ValidationError("--iso and --no-iso don't go together.")
        }
        _ = try hardware.disk.map { try parseGigabytes($0, name: "--disk") }
        let memoryBytes = try hardware.memory.map { try parseGigabytes($0, name: "--memory") }
        try validateResources(cpu: hardware.cpu, memory: memoryBytes)
        if let display = hardware.display, Self.screenSize(display) == nil {
            throw ValidationError("--display must look like 1920x1080, between 640x480 and 7680x4320.")
        }
    }

    private var changesSomething: Bool {
        let changesHardware =
            hardware.cpu != nil || hardware.memory != nil || hardware.disk != nil || hardware.display != nil
        let changesDevices =
            devices.iso != nil || devices.noIso || devices.clipboard != nil || devices.audio != nil
            || devices.rosetta != nil || devices.nested != nil
        let changesNetwork = networking.network != nil || networking.newMac
        let changesOther = other.sshUser != nil || other.autostart != nil
        return changesHardware || changesDevices || changesNetwork || changesOther
    }

    private static func screenSize(_ display: String) -> (width: Int, height: Int)? {
        let parts = display.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, VMSettings.screenWidths.contains(parts[0]),
            VMSettings.screenHeights.contains(parts[1])
        else { return nil }
        return (parts[0], parts[1])
    }

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        let diskBytes = try hardware.disk.map { try parseGigabytes($0, name: "--disk") }
        let isoPath = try devices.iso.map(Self.existingISOPath)
        if let diskBytes { try Self.checkDiskCanGrow(bundle, to: diskBytes) }

        try VMSettings.change(bundle) { config in try applyRequested(to: &config, isoPath: isoPath) }
        if let diskBytes {
            try VMLibrary.withStoppedVM(bundle) { try bundle.resizeDisk(to: diskBytes) }
        }

        print("Updated '\(name)'.")
    }

    /// Checked before the settings are saved, so a refused disk size leaves the VM as it was.
    private static func checkDiskCanGrow(_ bundle: VMBundle, to bytes: UInt64) throws {
        try VMLibrary.withStoppedVM(bundle) { try bundle.checkDiskCanGrow(to: bytes) }
    }

    private static func existingISOPath(_ iso: String) throws -> String {
        let url = URL(userPath: iso).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HangarError("ISO not found: \(url.path)")
        }
        return url.path
    }

    /// Only sets what was asked for; VMSettings decides whether the change is allowed.
    private func applyRequested(to config: inout VMConfig, isoPath: String?) throws {
        if let cpu = hardware.cpu { config.cpuCount = cpu }
        if let memory = hardware.memory { config.memorySize = try parseGigabytes(memory, name: "--memory") }
        if let size = hardware.display.flatMap(Self.screenSize) {
            config.display.width = size.width
            config.display.height = size.height
        }
        if let network = networking.network { config.network.mode = network }
        if networking.newMac { config.network.macAddress = VMConfig.randomMACAddress() }

        if let isoPath { config.isoPath = isoPath }
        if devices.noIso { config.isoPath = nil }
        if let rosetta = devices.rosetta { config.rosetta = rosetta == .on }
        if let nested = devices.nested { config.usesNestedVirtualization = nested == .on }
        if let audio = devices.audio { config.audio = audio == .on }
        if let clipboard = devices.clipboard { config.clipboard = clipboard == .on }

        if let sshUser = other.sshUser { config.sshUser = sshUser }
        if let autostart = other.autostart { config.autoStart = autostart == .on }
    }
}
