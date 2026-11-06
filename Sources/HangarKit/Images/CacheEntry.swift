import Foundation

package struct CacheEntry: Identifiable, Hashable, Sendable {
    package enum Kind: String, CaseIterable, Sendable {
        case macOS = "macOS"
        case installedMacOS = "Installed macOS"
        case image = "Images"
        case linux = "Linux"
        case windows = "Windows"
        case other = "Other"
    }

    package let url: URL
    package let kind: Kind
    package let title: String
    package let size: UInt64
    package let lastUsed: Date

    package var id: URL { url }
}
