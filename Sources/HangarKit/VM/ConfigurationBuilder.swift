import Foundation
import HangarSupport
import Virtualization

package enum ConsoleMode: Sendable {
    case stdio
    case none
}

struct ConfigurationBuilder {
    enum Purpose {
        case run
        case install
    }

    let bundle: VMBundle
    let config: VMConfig
    var purpose: Purpose = .run
    var console: ConsoleMode = .none
    var bootISO: URL?
    var playsAudio = true
    var windowsInstallMedia: URL?
    var agentInput: FileHandle?
    var agentOutput: FileHandle?
    var usbPassthrough = false
    var guestNetwork: FileHandle?

    // The guest agents open these ports by name (`COMMAND_PORT` and `REPORT_PORT` in guest-agent's hangar_guest_*).
    static let agentPortName = "io.baseguard.hangar.agent"
    static let reportPortName = "io.baseguard.hangar.report"

    static let linuxShareTag = "hangar"
    static let rosettaShareTag = "rosetta"

    func build() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        // VM names (up to 40 letters, digits and "-") always fit the label's rules; macOS shows it in some services.
        configuration.label = bundle.name
        configuration.cpuCount = min(
            max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(
            max(config.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        switch config.os {
        case .windows: try configureWindows(configuration)
        case .macOS: try configureMac(configuration)
        case .linux: try configureLinux(configuration)
        }
        configuration.consoleDevices = consoleDevices(agentPorts() + (config.clipboard ? [clipboardPort()] : []))
        configuration.storageDevices = try storageDevices()
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // `hangar exec` connects to the guest agent through it (ExecBridge).
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if purpose == .run {
            configuration.networkDevices = try networkDevices()
            configuration.directorySharingDevices = try directorySharingDevices()
            configuration.audioDevices = config.audio && config.os.supportsAudio && playsAudio ? [soundDevice()] : []
            if usbPassthrough {
                configuration.usbControllers = [VZXHCIControllerConfiguration()]
            }
        }

        try configuration.validate()
        return configuration
    }

    private func storageDevices() throws -> [VZStorageDeviceConfiguration] {
        guard FileManager.default.fileExists(atPath: bundle.diskURL.path) else {
            throw HangarError("'\(bundle.name)' can't start: its disk \(bundle.diskURL.path) is missing.")
        }

        // Automatic caching has zeroed Linux guests' file pages and crashed their kernels; cached avoids it.
        let system = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .full
        )
        var devices: [VZStorageDeviceConfiguration] = [
            config.os == .windows
                ? VZNVMExpressControllerDeviceConfiguration(attachment: system)
                : VZVirtioBlockDeviceConfiguration(attachment: system)
        ]

        if config.os == .linux, FileManager.default.fileExists(atPath: bundle.cloudInitURL.path) {
            devices.append(
                VZVirtioBlockDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.cloudInitURL, readOnly: true)
                ))
        }

        if config.os == .windows, let windowsInstallMedia {
            devices.append(
                VZUSBMassStorageDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(url: windowsInstallMedia, readOnly: false)
                ))
        }

        if config.os.supportsISO, let iso = bootISO ?? config.isoPath.map({ URL(fileURLWithPath: $0) }) {
            guard FileManager.default.fileExists(atPath: iso.path) else {
                throw HangarError("ISO not found: \(iso.path)")
            }
            devices.append(
                VZUSBMassStorageDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
                ))
        }

        return devices
    }

    private func soundDevice() -> VZAudioDeviceConfiguration {
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        return sound
    }

    private func configureMac(_ configuration: VZVirtualMachineConfiguration) throws {
        guard let modelData = config.hardwareModel,
            let model = VZMacHardwareModel(dataRepresentation: modelData)
        else {
            throw HangarError("'\(bundle.name)' has no valid hardware model.")
        }
        guard model.isSupported else {
            throw HangarError("This Mac cannot run '\(bundle.name)': its hardware model is not supported here.")
        }
        guard let identifierData = config.machineIdentifier,
            let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData)
        else {
            throw HangarError("'\(bundle.name)' has no valid machine identifier.")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.nvramURL)
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.width,
                heightInPixels: config.display.height,
                pixelsPerInch: config.display.pixelsPerInch
            )
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [
            VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration(),
        ]
    }

    private func configureLinux(_ configuration: VZVirtualMachineConfiguration) throws {
        let platform = VZGenericPlatformConfiguration()
        if let data = config.machineIdentifier, let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        }
        try allowNestedVirtualizationIfAsked(on: platform)
        configureEFIGuest(configuration, on: platform)
        configuration.serialPorts = serialPorts()
    }

    private func configureWindows(_ configuration: VZVirtualMachineConfiguration) throws {
        let platform = try WindowsPlatform.make(machineIdentifier: config.machineIdentifier)
        try allowNestedVirtualizationIfAsked(on: platform)
        configureEFIGuest(configuration, on: platform)
    }

    private func allowNestedVirtualizationIfAsked(on platform: VZGenericPlatformConfiguration) throws {
        guard config.usesNestedVirtualization else { return }
        try VMSettings.checkNestedVirtualization(for: config.os)
        platform.isNestedVirtualizationEnabled = true
    }

    /// Linux and Windows boot through EFI, with a virtio screen and a USB keyboard and pointer.
    private func configureEFIGuest(_ configuration: VZVirtualMachineConfiguration, on platform: VZPlatformConfiguration)
    {
        configuration.platform = platform
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.nvramURL)
        configuration.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: config.guestDisplay.width, heightInPixels: config.guestDisplay.height)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private func serialPorts() -> [VZSerialPortConfiguration] {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment =
            console == .stdio
            ? VZFileHandleSerialPortAttachment(
                fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
            : VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: nil)
        return [port]
    }

    private func consoleDevices(_ ports: [VZVirtioConsolePortConfiguration]) -> [VZVirtioConsoleDeviceConfiguration] {
        guard !ports.isEmpty else { return [] }
        let device = VZVirtioConsoleDeviceConfiguration()
        for (index, port) in ports.enumerated() {
            device.ports[index] = port
        }
        return [device]
    }

    private func agentPorts() -> [VZVirtioConsolePortConfiguration] {
        guard let agentInput, let agentOutput else { return [] }
        let commands = VZVirtioConsolePortConfiguration()
        commands.name = Self.agentPortName
        commands.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: agentInput, fileHandleForWriting: nil)
        let reports = VZVirtioConsolePortConfiguration()
        reports.name = Self.reportPortName
        reports.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: agentOutput)
        return [commands, reports]
    }

    private func clipboardPort() -> VZVirtioConsolePortConfiguration {
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        port.attachment = spice
        return port
    }

    private func networkDevices() throws -> [VZNetworkDeviceConfiguration] {
        let attachment: VZNetworkDeviceAttachment

        switch config.network.mode {
        case .managed:
            guard let guestNetwork else {
                throw HangarError("Hangar's network is not available.")
            }
            attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: guestNetwork)
        case .nat:
            attachment = VZNATNetworkDeviceAttachment()
        case .none:
            return []
        }

        guard let mac = VZMACAddress(string: config.network.macAddress) else {
            throw HangarError("Invalid MAC address '\(config.network.macAddress)'.")
        }

        let device = VZVirtioNetworkDeviceConfiguration()
        device.macAddress = mac
        device.attachment = attachment

        return [device]
    }

    static func shareTag(for os: GuestOS) -> String {
        os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : linuxShareTag
    }

    static func directoryShare(for folders: [SharedFolder], tools: URL) throws -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [
            GuestTools.shareName: VZSharedDirectory(url: tools, readOnly: true)
        ]

        for folder in folders {
            guard !SharedFolder.isReserved(folder.name) else {
                throw HangarError(
                    "A shared folder can't be called '\(folder.name)': Hangar uses that name for its own folder.")
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
            else {
                throw HangarError("Shared folder '\(folder.name)' does not exist: \(folder.path)")
            }
            try folder.checkSafe()
            directories[folder.name] = VZSharedDirectory(
                url: URL(fileURLWithPath: folder.path), readOnly: folder.readOnly)
        }

        return VZMultipleDirectoryShare(directories: directories)
    }

    private func directorySharingDevices() throws -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        let device = VZVirtioFileSystemDeviceConfiguration(tag: Self.shareTag(for: config.os))
        device.share = try Self.directoryShare(for: config.sharedFolders, tools: GuestTools.folder(for: config.os))
        devices.append(device)

        if config.os == .linux, config.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let device = VZVirtioFileSystemDeviceConfiguration(tag: Self.rosettaShareTag)
                device.share = try VZLinuxRosettaDirectoryShare()
                devices.append(device)
            case .notInstalled:
                throw HangarError("Rosetta is not installed. Run: softwareupdate --install-rosetta")
            case .notSupported:
                throw HangarError("Rosetta for Linux is not supported on this Mac.")
            @unknown default:
                throw HangarError("Rosetta for Linux is not supported on this Mac.")
            }
        }

        return devices
    }
}
