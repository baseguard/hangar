import Virtualization

package enum MachineState: String, Codable, Sendable {
    case stopped
    case running
    case paused
    case error
    case starting
    case pausing
    case resuming
    case stopping
    case saving
    case restoring
    case unknown

    package init(_ state: VZVirtualMachine.State) {
        switch state {
        case .stopped: self = .stopped
        case .running: self = .running
        case .paused: self = .paused
        case .error: self = .error
        case .starting: self = .starting
        case .pausing: self = .pausing
        case .resuming: self = .resuming
        case .stopping: self = .stopping
        case .saving: self = .saving
        case .restoring: self = .restoring
        @unknown default: self = .unknown
        }
    }
}

extension VZVirtualMachine.State {
    package var name: String { MachineState(self).rawValue }
}
