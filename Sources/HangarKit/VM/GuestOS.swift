import Foundation
import HangarSupport

package enum GuestOS: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case linux
    case windows

    package var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        }
    }

    package var supportsAudio: Bool { self != .windows }

    package var supportsRosetta: Bool { self == .linux }

    /// Virtualization offers nested virtualization only on the generic platform that Linux and Windows run on.
    package var supportsNestedVirtualization: Bool { self != .macOS }

    package var supportsISO: Bool { self != .windows }

    package var defaultCPUCount: Int {
        switch self {
        case .macOS, .windows: 4
        case .linux: 2
        }
    }

    package var defaultMemorySize: UInt64 {
        switch self {
        case .macOS, .windows: 8 * ByteSize.gib
        case .linux: 4 * ByteSize.gib
        }
    }

    package var defaultDiskSize: UInt64 {
        switch self {
        case .macOS: 80 * ByteSize.gib
        case .windows: 64 * ByteSize.gib
        case .linux: 20 * ByteSize.gib
        }
    }

    package var minimumDiskSize: UInt64 {
        switch self {
        case .macOS, .windows: 48 * ByteSize.gib
        case .linux: 8 * ByteSize.gib
        }
    }

    var defaultDisplay: DisplaySettings {
        switch self {
        case .macOS: .macDefault
        case .linux: .linuxDefault
        case .windows: WindowsPlatform.display
        }
    }
}
