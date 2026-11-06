import SwiftUI

struct SelectionFollowing: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var selection: SidebarItem?
    @Binding var lastSelected: String
    @Binding var newVM: NewVMRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.request?.id, initial: true) { followNewVMRequest() }
            .onMessage(VirtualMachineRenamedMessage.self) { message in
                guard selection == .vm(message.oldName) else { return }
                selection = .vm(message.newName)
            }
            .onChange(of: store.jobs.map(\.id)) { followFinishedJob() }
            .onChange(of: store.vms.map(\.name)) { followFinishedJob() }
            .onChange(of: selection) {
                if case .vm(let name) = selection { lastSelected = name }
            }
            .onChange(of: store.hasScanned, initial: true) { restoreLastSelected() }
    }

    private func followNewVMRequest() {
        switch store.request?.kind {
        case .newVM(let kind):
            newVM = NewVMRequest(kind: kind)
        case .newVMFromTemplate(let template):
            newVM = NewVMRequest(template: template)
        case .page, .dialog, nil:
            return
        }
        store.request = nil
    }

    /// The first scan can finish after the window appears, so the last VM is picked once it shows up.
    private func restoreLastSelected() {
        guard selection == nil, store.vm(lastSelected) != nil else { return }
        selection = .vm(lastSelected)
    }

    private func followFinishedJob() {
        guard case .job(let id) = selection, !store.jobs.contains(where: { $0.id == id }),
            let name = store.finishedJobs[id], store.vm(name) != nil
        else { return }
        selection = .vm(name)
    }
}
