import HangarKit
import HangarSupport

extension CreateVMView {
    nonisolated enum Choice: String, CaseIterable, Identifiable, Sendable {
        case macOS = "macos"
        case macOSHomebrew = "macos-homebrew"
        case macOSXcode = "macos-xcode"
        case ipsw
        case debian
        case ubuntu
        case fedora
        case omarchy
        case linuxISO = "iso"
        case cloudImage = "cloud-image"
        case windows
        case registry

        var id: String { rawValue }

        var kind: Kind {
            switch self {
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw: .macOS
            case .debian, .ubuntu, .fedora, .omarchy, .linuxISO, .cloudImage: .linux
            case .windows: .windows
            case .registry: .registry
            }
        }

        var title: String {
            switch self {
            case .macOS: "Vanilla"
            case .macOSHomebrew: "Base"
            case .macOSXcode: "Xcode"
            case .ipsw: "IPSW"
            case .debian, .ubuntu, .fedora: linuxImage?.title ?? ""
            case .omarchy: linuxInstaller?.title ?? ""
            case .linuxISO: "ISO"
            case .cloudImage: "Cloud image from a URL"
            case .windows: "Windows 11"
            case .registry: "From an Image"
            }
        }

        var summary: String {
            switch self {
            case .macOS:
                "The latest macOS as Apple installs it, never started. Downloaded once from Hangar's registry with every part checked."
            case .macOSHomebrew:
                "The latest macOS with the Command Line Tools, Homebrew and Hangar's agent. Downloaded once from Hangar's registry with every part checked."
            case .macOSXcode:
                "The base image with Xcode and the iOS platform, so it's a larger download. Downloaded once from Hangar's registry with every part checked."
            case .ipsw:
                "The latest macOS for this Mac, downloaded from Apple as an IPSW and installed. Installing takes 10–20 minutes."
            case .debian, .ubuntu:
                "The latest \(title) cloud image from \(linuxImage?.source ?? ""), checked against its published checksum and downloaded once."
            case .fedora:
                "The \(title) cloud image from Fedora's mirrors, checked against the checksum Hangar knows for it and downloaded once."
            case .omarchy:
                "Omarchy's Arm installer ISO from \(linuxInstaller?.source ?? ""), checked against the checksum Hangar knows for it and downloaded once (6 GB). Install it from the VM's window, then detach the ISO."
            case .linuxISO, .cloudImage, .windows, .registry: ""
            }
        }

        var baseName: String {
            switch self {
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw: "macos"
            case .debian, .ubuntu, .fedora, .omarchy: rawValue
            case .linuxISO, .cloudImage: "linux"
            case .windows: "windows"
            case .registry: "vm"
            }
        }

        var macImage: String? {
            switch self {
            case .macOS: "vanilla"
            case .macOSHomebrew: "base"
            case .macOSXcode: "xcode"
            case .ipsw, .debian, .ubuntu, .fedora, .omarchy, .linuxISO, .cloudImage, .windows, .registry: nil
            }
        }

        var linuxImage: LinuxCloudImage? {
            switch self {
            case .debian: .debian
            case .ubuntu: .ubuntu
            case .fedora: .fedora
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw, .omarchy, .linuxISO, .cloudImage, .windows, .registry:
                nil
            }
        }

        var linuxInstaller: LinuxInstallerISO? {
            switch self {
            case .omarchy: .omarchy
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw, .debian, .ubuntu, .fedora, .linuxISO, .cloudImage,
                .windows, .registry:
                nil
            }
        }

        /// The size the form starts with: an installer like Omarchy needs more than its system's defaults.
        var defaultResources: (cpus: Int, memoryGB: Int, diskGB: Int) {
            let os = kind.os ?? .linux
            let memory = linuxInstaller?.defaultMemorySize ?? os.defaultMemorySize
            let disk = linuxInstaller?.defaultDiskSize ?? os.defaultDiskSize
            return (
                linuxInstaller?.defaultCPUCount ?? os.defaultCPUCount, Int(memory / ByteSize.gib),
                Int(disk / ByteSize.gib)
            )
        }
    }
}
