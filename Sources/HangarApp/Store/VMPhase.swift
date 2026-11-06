import HangarKit
import SwiftUI

enum VMPhase: Equatable {
    case stopped
    case running
    case paused
    case busy(String)
    case failed

    init(_ state: MachineState) {
        switch state {
        case .running: self = .running
        case .paused: self = .paused
        case .stopped: self = .stopped
        case .error: self = .failed
        case .starting, .pausing, .resuming, .stopping, .saving, .restoring, .unknown:
            self = .busy(state.rawValue.capitalized)
        }
    }

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .running: "Running"
        case .paused: "Paused"
        case .busy(let state): state
        case .failed: "Error"
        }
    }

    var color: Color {
        switch self {
        case .stopped: .secondary
        case .running: .green
        case .paused: .yellow
        case .busy: .orange
        case .failed: .red
        }
    }
}
