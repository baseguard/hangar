package enum ControlRequest: Codable, Equatable, Sendable {
    case status
    case memory
    case stop
    case forceStop
    case pause
    case resume
    case reloadTrafficRules
    case reloadSecrets
    case reloadSharedFolders
    case takeSnapshot(name: String)
    /// Turns the connection into a stream of exec frames once the VM replies `done`.
    case exec(ExecRequest)
}
