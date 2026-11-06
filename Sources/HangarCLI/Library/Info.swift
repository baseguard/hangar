import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a VM's settings: processors, memory, disk, network, devices.")

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        let config = try bundle.loadConfig()
        let run = bundle.runInfo

        let rows =
            Self.machineRows(bundle, config, run: run) + Self.networkRows(config, run: run)
            + Self.deviceRows(bundle, config) + Self.startRows(bundle, config)
        printFields(rows)
    }

    private static func machineRows(_ bundle: VMBundle, _ config: VMConfig, run: RunInfo?) -> [(String, String)] {
        let state = run.map { "running in \($0.host == .app ? "Hangar.app" : "hangar CLI") (pid \($0.pid))" }
        return [
            ("Name", bundle.name),
            ("OS", config.os.displayName),
            ("State", state ?? "stopped"),
            ("CPUs", "\(config.cpuCount)"),
            ("Memory", ByteSize.format(config.memorySize)),
            ("Disk", "\(ByteSize.format(bundle.diskSize)) (\(ByteSize.format(bundle.allocatedSize)) used)"),
            ("Display", "\(config.guestDisplay.width)×\(config.guestDisplay.height)"),
        ]
    }

    private static func networkRows(_ config: VMConfig, run: RunInfo?) -> [(String, String)] {
        var rows = [("Network", config.network.mode.displayName), ("MAC", config.network.macAddress)]
        if config.network.mode == .managed, let ip = config.network.ipAddress {
            rows.append(("Reserved IP", ip))
        }
        if let run, let ip = IPResolver.ipAddress(for: config, startedAt: run.startedAt) {
            rows.append(("Current IP", ip))
        }
        return rows
    }

    private static func deviceRows(_ bundle: VMBundle, _ config: VMConfig) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let iso = config.isoPath { rows.append(("ISO", iso)) }

        if config.os == .linux {
            rows.append(("Rosetta", config.rosetta ? "on" : "off"))
            if FileManager.default.fileExists(atPath: bundle.cloudInitURL.path) {
                rows.append(("Cloud-init", "settings attached (\(bundle.cloudInitURL.lastPathComponent))"))
            }
        }

        rows.append(("Clipboard", config.clipboard ? "shared" : "not shared"))
        if config.os.supportsNestedVirtualization {
            rows.append(("Nested virtualization", config.usesNestedVirtualization ? "on" : "off"))
        }

        if config.os.supportsAudio {
            rows.append(("Audio", config.audio ? "on" : "off"))
        }

        for folder in config.sharedFolders {
            rows.append(("Share", "\(folder.name) → \(folder.path)\(folder.readOnly ? " (read-only)" : "")"))
        }

        return rows
    }

    private static func startRows(_ bundle: VMBundle, _ config: VMConfig) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let user = config.sshUser { rows.append(("SSH user", user)) }
        rows.append(("Autostart", config.autoStart ? "on (in the background, when Hangar.app opens)" : "off"))
        if config.provisioning != nil {
            rows.append(("Provisioning", "pending: the account password is in your Keychain until the next start"))
        }
        rows.append(("Path", bundle.url.path))
        return rows
    }
}
