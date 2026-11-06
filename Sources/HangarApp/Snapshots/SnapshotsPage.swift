import AppKit
import HangarKit
import SwiftUI

struct SnapshotsPage: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    @State private var newName = ""
    @State private var naming = false
    @State private var restoring: VMSnapshot?
    @State private var deleting: VMSnapshot?
    @State private var renaming: VMSnapshot?

    var body: some View {
        Group {
            if vm.snapshots.isEmpty {
                NoSnapshotsView(isBusy: isBusy, takeSnapshot: askForName)
            } else {
                SnapshotList(
                    vm: vm, isBusy: isBusy, restoring: $restoring, deleting: $deleting, takeSnapshot: askForName,
                    rename: askForNewName)
            }
        }
        .modifier(TakeSnapshotAlert(vm: vm, isPresented: $naming, name: $newName))
        .modifier(RenameSnapshotAlert(vm: vm, renaming: $renaming, name: $newName))
        .modifier(RestoreSnapshotConfirmation(vm: vm, restoring: $restoring))
        .modifier(DeleteSnapshotConfirmation(vm: vm, deleting: $deleting))
    }

    private var isBusy: Bool { store.busy.contains(vm.name) }

    private func askForName() {
        newName = Snapshots.defaultName()
        naming = true
    }

    private func askForNewName(of snapshot: VMSnapshot) {
        newName = snapshot.name
        renaming = snapshot
    }
}

private struct NoSnapshotsView: View {
    let isBusy: Bool
    let takeSnapshot: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Snapshots", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(
                "A snapshot is an instant copy of the disk you can return to."
            )
        } actions: {
            Button("Take Snapshot…", action: takeSnapshot)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
    }
}

private struct SnapshotList: View {
    let vm: VMItem
    let isBusy: Bool
    @Binding var restoring: VMSnapshot?
    @Binding var deleting: VMSnapshot?
    let takeSnapshot: () -> Void
    let rename: (VMSnapshot) -> Void

    var body: some View {
        List {
            Section {
                ForEach(vm.snapshots.reversed()) { snapshot in
                    SnapshotRow(
                        vm: vm, snapshot: snapshot, isBusy: isBusy, canRestore: canRestore,
                        restore: { restoring = snapshot }, delete: { deleting = snapshot }
                    )
                    .contextMenu {
                        SnapshotMenu(
                            vm: vm, snapshot: snapshot, isBusy: isBusy, canRestore: canRestore,
                            restore: { restoring = snapshot }, rename: { rename(snapshot) },
                            delete: { deleting = snapshot })
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Restore…", systemImage: "clock.arrow.circlepath") { restoring = snapshot }
                            .tint(.accentColor)
                            .disabled(!canRestore)
                        Button("Delete…", systemImage: "trash") { deleting = snapshot }
                            .tint(.red)
                            .disabled(isBusy)
                    }
                }
            } header: {
                SnapshotListHeader(count: vm.snapshots.count, isBusy: isBusy, takeSnapshot: takeSnapshot)
            } footer: {
                Text(
                    "Snapshots are copy-on-write copies of the disk: instant, and they only take space as the disk changes. A VM restored to one starts up fresh."
                )
                .font(.callout.weight(.regular))
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var canRestore: Bool { !vm.isRunning && !isBusy }
}

private struct SnapshotListHeader: View {
    let count: Int
    let isBusy: Bool
    let takeSnapshot: () -> Void

    var body: some View {
        HStack {
            Text("\(count) Snapshot\(count == 1 ? "" : "s")")
                .font(.headline)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Take Snapshot…", action: takeSnapshot)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
    }
}

private struct SnapshotRow: View {
    let vm: VMItem
    let snapshot: VMSnapshot
    let isBusy: Bool
    let canRestore: Bool
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            SymbolBadge(systemImage: "internaldrive.fill", tint: .gray)
            VStack(alignment: .leading) {
                Text(snapshot.name).fontWeight(.medium)
                Text(snapshot.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("New VM…") { VMDialog.clone(vm.name, snapshot: snapshot).post() }
                .disabled(isBusy)
                .help("Create a new VM from this snapshot")
            Button("Restore…", action: restore)
                .disabled(!canRestore)
                .help(vm.isRunning ? "Shut down the VM to restore a snapshot" : "Restore the VM to this snapshot")
            Button(action: delete) {
                Image(systemName: "trash").minimumHitArea()
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .help("Delete this snapshot")
            .accessibilityLabel("Delete \(snapshot.name)")
        }
    }
}

private struct SnapshotMenu: View {
    let vm: VMItem
    let snapshot: VMSnapshot
    let isBusy: Bool
    let canRestore: Bool
    let restore: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("New VM from Snapshot…") { VMDialog.clone(vm.name, snapshot: snapshot).post() }
            .disabled(isBusy)
        Button("Restore…", action: restore)
            .disabled(!canRestore)
        Button("Rename…", action: rename)
            .disabled(isBusy)
        Button("Export…") { VMDialog.export(vm.name, snapshot: snapshot).post() }
            .disabled(vm.config.os == .macOS)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.url]) }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
            .disabled(isBusy)
    }
}

private struct TakeSnapshotAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @Binding var isPresented: Bool
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert("Take a Snapshot of “\(vm.name)”", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Take Snapshot") {
                store.takeSnapshot(of: vm.name, named: name.trimmingCharacters(in: .whitespaces))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                vm.isRunning
                    ? "The VM pauses for a moment while its disk is saved."
                    : "An instant copy-on-write copy of the disk.")
        }
    }
}

private struct RenameSnapshotAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @Binding var renaming: VMSnapshot?
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert(
            "Rename “\(renaming?.name ?? "")”", isPresented: isPresented($renaming), presenting: renaming
        ) { snapshot in
            TextField("Name", text: $name)
            Button("Rename") {
                store.renameSnapshot(snapshot, of: vm.name, to: name.trimmingCharacters(in: .whitespaces))
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct RestoreSnapshotConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @Binding var restoring: VMSnapshot?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Restore “\(vm.name)” to “\(restoring?.name ?? "")”?",
            isPresented: isPresented($restoring),
            titleVisibility: .visible, presenting: restoring
        ) { snapshot in
            Button("Restore") { store.restoreSnapshot(snapshot, of: vm.name) }
        } message: { _ in
            Text("The current disk is replaced. Take a snapshot first to keep the changes since then.")
        }
    }
}

private struct DeleteSnapshotConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @Binding var deleting: VMSnapshot?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete the snapshot “\(deleting?.name ?? "")”?",
            isPresented: isPresented($deleting),
            titleVisibility: .visible, presenting: deleting
        ) { snapshot in
            Button("Delete") { store.deleteSnapshot(snapshot, of: vm.name) }
        } message: { _ in
            Text("This can't be undone.")
        }
    }
}
