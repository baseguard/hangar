import HangarKit
import SwiftUI

extension GuestOS {
    var symbolName: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "terminal.fill"
        case .windows: "pc"
        }
    }

    var tint: Color {
        switch self {
        // A cool gray of Hangar's own: the system grays are too light on a tinted pill.
        case .macOS: Color(red: 0.36, green: 0.38, blue: 0.44)
        case .linux: .orange
        case .windows: .blue
        }
    }
}
