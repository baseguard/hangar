/// A start that waits for the user to make a VM copied outside Hangar a separate VM, so it doesn't run as its twin.
nonisolated struct TwinStart: Sendable {
    let vm: String
    let twin: String
    let recovery: Bool
    let inBackground: Bool
}
