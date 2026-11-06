import HangarKit

extension CreateVMView {
    nonisolated enum Kind: String, CaseIterable, Identifiable, Sendable {
        case macOS = "macOS"
        case linux = "Linux"
        case windows = "Windows"
        case registry = "Registry"

        var id: String { rawValue }

        var os: GuestOS? {
            switch self {
            case .macOS: .macOS
            case .linux: .linux
            case .windows: .windows
            case .registry: nil
            }
        }

        var title: String {
            switch self {
            case .macOS: "macOS"
            case .linux: "Linux"
            case .windows: "Windows 11"
            case .registry: "From an Image"
            }
        }

        var blurb: String {
            switch self {
            case .macOS: "Hangar's ready images of the latest macOS, or an install from Apple's latest IPSW."
            case .linux: "Debian or Ubuntu ready in seconds, or any Arm64 ISO or cloud image."
            case .windows: "Installs Windows 11 on Arm unattended from Microsoft's ISO."
            case .registry: "Your team's image from a container registry or a file."
            }
        }

        var formTitle: String {
            os == nil ? title : "New \(title) VM"
        }

        var choices: [Choice] { Choice.allCases.filter { $0.kind == self } }

        var quickChoices: [Choice] {
            switch self {
            case .macOS: [.macOSHomebrew, .macOSXcode]
            case .linux: [.debian, .ubuntu]
            case .windows, .registry: []
            }
        }

        var quickDefault: Choice {
            self == .macOS ? .macOSHomebrew : advancedDefault
        }

        var advancedDefault: Choice {
            switch self {
            case .macOS: .macOS
            case .linux: .debian
            case .windows: .windows
            case .registry: .registry
            }
        }
    }
}
