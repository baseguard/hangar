import HangarKit

extension CreateVMView {
    nonisolated enum Choice: String, CaseIterable, Identifiable, Sendable {
        case macOS = "macos"
        case macOSHomebrew = "macos-homebrew"
        case macOSXcode = "macos-xcode"
        case ipsw
        case debian
        case ubuntu
        case linuxISO = "iso"
        case cloudImage = "cloud-image"
        case windows
        case registry

        var id: String { rawValue }

        var kind: Kind {
            switch self {
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw: .macOS
            case .debian, .ubuntu, .linuxISO, .cloudImage: .linux
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
            case .debian, .ubuntu: linuxImage?.title ?? ""
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
            case .linuxISO, .cloudImage, .windows, .registry: ""
            }
        }

        var baseName: String {
            switch self {
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw: "macos"
            case .debian, .ubuntu: rawValue
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
            case .ipsw, .debian, .ubuntu, .linuxISO, .cloudImage, .windows, .registry: nil
            }
        }

        var linuxImage: LinuxCloudImage? {
            switch self {
            case .debian: .debian
            case .ubuntu: .ubuntu
            case .macOS, .macOSHomebrew, .macOSXcode, .ipsw, .linuxISO, .cloudImage, .windows, .registry: nil
            }
        }
    }
}
