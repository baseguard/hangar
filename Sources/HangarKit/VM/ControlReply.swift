package enum ControlReply: Codable, Equatable, Sendable {
    case done
    case state(MachineState)
    case report(GuestReport?)
    case failed(String)
}

extension ControlReply {
    package var machineState: MachineState? {
        if case .state(let state) = self { state } else { nil }
    }
}
