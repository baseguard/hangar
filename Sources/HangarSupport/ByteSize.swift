import Foundation

package enum ByteSize {
    package static let mib: UInt64 = 1 << 20
    package static let gib: UInt64 = 1 << 30

    package static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
