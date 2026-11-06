import HangarKit
import SwiftUI

struct LibraryDialogs: ViewModifier {
    @Environment(VMStore.self) private var store
    @State private var dialogName = ""
    @State private var renaming: String?
    @State private var cloning: String?
    @State private var cloningSnapshot: VMSnapshot?
    @State private var deleting: String?
    @State private var stopping: String?
    @State private var installingAgent: AgentInstallTarget?
    @State private var askingAgentPassword: AgentPasswordRequest?
    @State private var exporting: ExportTarget?
    @State private var savingTemplate: String?
    @State private var separating: TwinStart?

    func body(content: Content) -> some View {
        content
            .modifier(RenameAlert(renaming: $renaming, name: $dialogName, nameProblem: nameProblem))
            .modifier(
                CloneAlert(cloning: $cloning, snapshot: cloningSnapshot, name: $dialogName, nameProblem: nameProblem)
            )
            .modifier(DeleteConfirmation(deleting: $deleting))
            .modifier(ForceStopConfirmation(stopping: $stopping))
            .sheet(item: $installingAgent) { target in AgentInstallSheet(target: target) }
            .modifier(AgentPasswordAlert(request: $askingAgentPassword))
            .sheet(item: $exporting) { target in ExportSheet(target: target) }
            .modifier(SaveTemplateExporter(saving: $savingTemplate))
            .modifier(SeparateAlert(separating: $separating, name: $dialogName, nameProblem: nameProblem))
            .onChange(of: store.request?.id, initial: true) {
                guard case .dialog(let dialog)? = store.request?.kind else { return }
                store.request = nil
                present(dialog)
            }
    }

    private var nameProblem: String? {
        let name = dialogName.trimmingCharacters(in: .whitespaces)
        if name == renaming { return nil }
        return store.nameProblem(name, ignoring: renaming ?? separating?.vm)
    }

    /// Finder names a copy “deb copy”, which isn't a valid VM name; the copy keeps a valid name as it is.
    private func separateName(for vm: String) -> String {
        if store.nameProblem(vm, ignoring: vm) == nil { return vm }
        let words = vm.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let base = String(words.joined(separator: "-").prefix(30))
        return store.uniqueName(base.isEmpty ? "vm" : base)
    }

    private func present(_ dialog: VMDialog) {
        switch dialog {
        case .rename(let name):
            dialogName = name
            renaming = name
        case .clone(let name, let snapshot):
            dialogName = store.uniqueName("\(name)-copy")
            cloningSnapshot = snapshot
            cloning = name
        case .delete(let name):
            deleting = name
        case .stop(let name):
            stopping = name
        case .installAgent(let name):
            let os = store.vm(name)?.config.os ?? .linux
            installingAgent = AgentInstallTarget(vm: name, os: os, isUpdate: store.usage[name]?.agentVersion != nil)
        case .agentPassword(let name, let wasWrong):
            askingAgentPassword = AgentPasswordRequest(vm: name, wasWrong: wasWrong)
        case .export(let name, let snapshot):
            exporting = ExportTarget(vm: name, os: store.vm(name)?.config.os ?? .linux, snapshot: snapshot)
        case .saveTemplate(let name):
            savingTemplate = name
        case .separate(let request):
            dialogName = separateName(for: request.vm)
            separating = request
        }
    }
}

private struct RenameAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var renaming: String?
    @Binding var name: String
    let nameProblem: String?

    func body(content: Content) -> some View {
        content.alert("Rename “\(renaming ?? "")”", isPresented: isPresented($renaming)) {
            TextField("Name", text: $name)
            Button("Rename") {
                if let renaming {
                    let newName = name.trimmingCharacters(in: .whitespaces)
                    Task { await store.rename(renaming, to: newName) }
                }
            }
            .disabled(nameProblem != nil || name.trimmingCharacters(in: .whitespaces) == renaming)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(nameProblem ?? VMLibrary.nameRule)
        }
    }
}

private struct CloneAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var cloning: String?
    let snapshot: VMSnapshot?
    @Binding var name: String
    let nameProblem: String?

    func body(content: Content) -> some View {
        content.alert(
            snapshot.map { "New VM from “\($0.name)”" } ?? "Clone “\(cloning ?? "")”",
            isPresented: isPresented($cloning)
        ) {
            TextField("Name", text: $name)
            Button("Clone") {
                if let cloning {
                    store.clone(cloning, snapshot: snapshot, as: name.trimmingCharacters(in: .whitespaces))
                }
            }
            .disabled(nameProblem != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An instant copy-on-write copy with its own MAC address, IP address and machine identity.")
        }
    }
}

private struct SeparateAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var separating: TwinStart?
    @Binding var name: String
    let nameProblem: String?

    func body(content: Content) -> some View {
        content.alert("“\(separating?.vm ?? "")” Was Copied Outside Hangar", isPresented: isPresented($separating)) {
            TextField("Name", text: $name)
            Button("Make Separate and Start") {
                if let separating {
                    let newName = name.trimmingCharacters(in: .whitespaces)
                    store.separateAndStart(separating, as: newName) { openWindow(id: DisplayWindow.id, value: $0) }
                }
            }
            .disabled(nameProblem != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(nameProblem ?? explanation)
        }
    }

    private var explanation: String {
        guard let separating else { return "" }
        let twin = separating.twin
        let changes =
            "It's the same VM as “\(twin)”, so neither can start. As a separate VM it gets its own network address, like a clone, and no secrets: those stay with “\(twin)”."
        guard store.vm(separating.vm)?.config.os == .macOS else { return changes }
        return changes + " Its new machine identity may ask you to sign in to Apple services again."
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var deleting: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete “\(deleting ?? "")”?", isPresented: isPresented($deleting), titleVisibility: .visible
        ) {
            Button("Delete") {
                if let deleting { store.delete(deleting) }
            }
        } message: {
            Text("The virtual machine, its disk and its snapshots are removed from this Mac. This can't be undone.")
        }
    }
}
