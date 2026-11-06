import AppKit
import HangarKit
import SwiftUI

struct Sidebar: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SidebarItem?
    let newVM: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Virtual Machines") {
                ForEach(store.vms) { vm in
                    SidebarVMRow(vm: vm, open: open)
                        .tag(SidebarItem.vm(vm.name))
                }
                ForEach(store.jobs) { job in
                    SidebarJobRow(job: job, selection: $selection)
                        .tag(SidebarItem.job(job.id))
                }
                if store.vms.isEmpty, store.jobs.isEmpty {
                    Button(action: newVM) {
                        Label("New Virtual Machine…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            UnreadableVMsSection()
            Section("This Mac") {
                NetworkRow()
                    .tag(SidebarItem.network)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { _ in
        } primaryAction: { items in
            guard items.count == 1, case .vm(let name) = items.first else { return }
            openWindow(id: DisplayWindow.id, value: name)
        }
        .toolbar {
            ToolbarItem {
                Button(action: newVM) {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("New Virtual Machine (⌘N)")
            }
        }
    }

    private func open(_ vm: VMItem) {
        if store.sessions[vm.name] != nil {
            openWindow(id: DisplayWindow.id, value: vm.name)
        } else if !vm.isRunning, !store.busy.contains(vm.name) {
            store.start(vm.name) { openWindow(id: DisplayWindow.id, value: $0) }
        }
    }
}

private struct SidebarVMRow: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let open: (VMItem) -> Void

    var body: some View {
        VMRow(vm: vm, usage: store.usage[vm.name], twin: store.twin(of: vm.name))
            .contextMenu { VMActionsMenu(vm: vm, managesLibrary: true) }
            .swipeActions(edge: .trailing) {
                if vm.isRunning {
                    Button("Shut Down", systemImage: "power") { store.shutdown(vm.name) }
                        .tint(.orange)
                } else {
                    Button("Start", systemImage: "play.fill") { open(vm) }
                        .tint(.green)
                        .disabled(store.busy.contains(vm.name))
                }
                Button("Delete…", systemImage: "trash") { VMDialog.delete(vm.name).post() }
                    .tint(.red)
                    .disabled(vm.isRunning)
            }
    }
}

private struct SidebarJobRow: View {
    @Environment(VMStore.self) private var store
    let job: CreationJob
    @Binding var selection: SidebarItem?

    var body: some View {
        JobRow(job: job)
            .contextMenu {
                if job.error == nil {
                    Button("Cancel Creation", role: .destructive) { store.cancelJob(job.id) }
                } else {
                    Button("Try Again") { selection = store.retryJob(job.id).map(SidebarItem.job) }
                    Button("Remove") { store.dismissJob(job.id) }
                }
            }
    }
}

private struct UnreadableVMsSection: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        if !store.unreadable.isEmpty {
            Section("Can't Open") {
                ForEach(store.unreadable.keys.sorted { $0.name < $1.name }) { bundle in
                    Label(bundle.name, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help(store.unreadable[bundle] ?? "")
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([bundle.configURL])
                            }
                        }
                }
            }
        }
    }
}
