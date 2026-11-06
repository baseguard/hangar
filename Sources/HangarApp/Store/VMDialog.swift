import HangarKit

nonisolated enum VMDialog: Sendable {
    case rename(String)
    case clone(String, snapshot: VMSnapshot? = nil)
    case delete(String)
    case stop(String)
    case installAgent(String)
    /// The update of the VM's agent needs the guest password; `wasWrong` after one that didn't work.
    case agentPassword(String, wasWrong: Bool)
    case export(String, snapshot: VMSnapshot? = nil)
    case saveTemplate(String)
    case separate(TwinStart)

    @MainActor
    func post() {
        VMStore.shared.ask(.dialog(self))
    }
}
