import Foundation
import HangarKit

/// Installing Hangar's agent in a VM by hand, and updating one that answers over `hangar exec`.
extension VMStore {
    /// Shares the Tools folder and shows the steps to run in the guest.
    func shareTools(with name: String) {
        guard let os = vm(name)?.config.os else { return }
        VMDialog.installAgent(name).post()
        Task {
            do {
                _ = try await runInBackground { try GuestTools.folder(for: os) }
                try await send(.reloadSharedFolders, to: name)
            } catch {
                report(error, doing: "share Hangar's Tools folder with \(name)")
            }
        }
    }

    /// A guest that needs a password for the update has it asked for, and the update runs again with it; only this
    /// update holds it.
    func updateAgent(_ name: String, password: String? = nil) {
        guard let vm = vm(name) else { return }
        let action = "update Hangar's agent in \(name)"
        guard beginBusy(name, doing: action) else { return }
        let os = vm.config.os

        // The task starts only after this method returns, so it finds its update in agentUpdates.
        let task = Task {
            defer {
                agentUpdates[name] = nil
                endBusy(name)
            }
            do {
                try await GuestAgentUpdate.update(vm.bundle, os: os, password: password) { step in
                    Task { @MainActor in self.showAgentUpdateStep(step, of: name) }
                }
            } catch let failure as GuestAgentUpdate.Failure {
                VMDialog.agentPassword(name, wasWrong: failure == .wrongPassword).post()
            } catch is CancellationError {
            } catch {
                report(error, doing: action)
            }
        }
        agentUpdates[name] = AgentUpdate(os: os, task: task)
    }

    /// Ends the update while its copy is copied in or started, even while Windows waits for the user to allow it;
    /// the copied agent is removed.
    func cancelAgentUpdate(of name: String) {
        guard let update = agentUpdates[name], update.canCancel else { return }
        agentUpdates[name]?.isCancelling = true
        update.task.cancel()
    }

    /// A step that arrives after the update has ended or while it is cancelled is dropped, so it can't stay on screen.
    private func showAgentUpdateStep(_ step: GuestAgentUpdate.Step, of name: String) {
        guard agentUpdates[name]?.isCancelling == false else { return }
        agentUpdates[name]?.step = step
    }
}

/// A running update of a VM's guest agent.
struct AgentUpdate {
    let os: GuestOS
    let task: Task<Void, Never>
    var step = GuestAgentUpdate.Step.copying
    var isCancelling = false

    var canCancel: Bool { !isCancelling && step.canCancel }

    /// What the update is doing, as the VM's windows show it.
    func status(vm: String) -> String {
        guard !isCancelling else { return "Cancelling the update of Hangar's agent in “\(vm)”…" }
        return step.message(os: os, vm: vm)
    }
}
