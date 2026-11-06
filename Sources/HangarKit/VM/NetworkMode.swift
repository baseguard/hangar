import Foundation

package enum NetworkMode: String, Codable, CaseIterable, Sendable {
    case managed
    case nat
    case none

    package var displayName: String {
        switch self {
        case .managed: "Hangar Managed"
        case .nat: "NAT"
        case .none: "None"
        }
    }
}
