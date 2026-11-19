import Foundation
import HangarSupport

/// A release's version, `1.2.3`, as Hangar's tags (`v1.2.3`) and Info.plist give it. A build that wasn't released
/// carries 0.0.0.
package struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    private let numbers: [Int]

    package init?(_ text: String) {
        guard let match = text.wholeMatch(of: /v?(\d{1,9})\.(\d{1,9})\.(\d{1,9})/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        numbers = [major, minor, patch]
    }

    /// The running Hangar's version; `nil` for a build without one.
    package static var running: AppVersion? { AppVersion(HangarVersion.current) }

    package var isRelease: Bool { numbers != [0, 0, 0] }

    package var description: String { numbers.map(String.init).joined(separator: ".") }

    package static func < (left: AppVersion, right: AppVersion) -> Bool {
        left.numbers.lexicographicallyPrecedes(right.numbers)
    }
}
