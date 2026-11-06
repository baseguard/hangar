import AppKit
import HangarKit
import SwiftUI

/// The Virtual Machine menu, in the menu bar and in a VM's window.
struct VMCommands: View {
    @Environment(VMStore.self) private var store
    let name: String?

    var body: some View {
        let vm = store.vm(name)
        let isRunning = vm?.isRunning == true
        let isBusy = name.map { store.busy.contains($0) } ?? true
        let isHosted = name.map { store.sessions[$0] != nil } ?? false
        Text(vm.map { "\($0.name) is \($0.phase.title.lowercased())" } ?? "No VM selected")
        Divider()
        StartItems(name: name, vm: vm, isRunning: isRunning, isBusy: isBusy, isHosted: isHosted)
        BrowseFilesItem(name: name, isRunning: isRunning)
        Divider()
        RunningItems(name: name, vm: vm, isRunning: isRunning)
        Divider()
        TakeSnapshotItem(name: name, vm: vm, isBusy: isBusy)
        Divider()
        LibraryItems(name: name, vm: vm, isRunning: isRunning)
        Divider()
        NetworkModePicker(name: name, vm: vm, isRunning: isRunning)
        ISOMenu(name: name, vm: vm, isBusy: isBusy)
        USBMenu(name: name, vm: vm, isHosted: isHosted)
        SharedFoldersMenu(name: name, vm: vm)
        GuestOptionToggles(name: name, vm: vm, isRunning: isRunning)
        GuestAgentItem(name: name, isRunning: isRunning, isBusy: isBusy)
    }
}

private struct StartItems: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let name: String?
    let vm: VMItem?
    let isRunning: Bool
    let isBusy: Bool
    let isHosted: Bool

    var body: some View {
        Button("Start") { if let name { store.start(name) { openWindow(id: DisplayWindow.id, value: $0) } } }
            .keyboardShortcut("r")
            .disabled(vm == nil || isRunning || isBusy)
        Button("Start in Background") { if let name { store.startInBackground(name) } }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(vm == nil || isRunning || isBusy)
        if vm?.config.os == .macOS {
            Button("Start in Recovery") {
                if let name { store.start(name, recovery: true) { openWindow(id: DisplayWindow.id, value: $0) } }
            }
            .disabled(isRunning || isBusy)
        }
        Button("Show Display") { if let name { openWindow(id: DisplayWindow.id, value: name) } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isHosted)
    }
}

/// Exec reaches a VM started in the background too, so a running VM is enough.
private struct BrowseFilesItem: View {
    @Environment(\.openWindow) private var openWindow
    let name: String?
    let isRunning: Bool

    var body: some View {
        Button("Browse Files…") { if let name { openWindow(id: FilesWindow.id, value: name) } }
            .disabled(!isRunning)
    }
}

private struct RunningItems: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?
    let isRunning: Bool

    var body: some View {
        Button(vm?.phase == .paused ? "Resume" : "Pause") {
            guard let vm else { return }
            if vm.phase == .paused {
                store.resume(vm.name)
            } else {
                store.pause(vm.name)
            }
        }
        .keyboardShortcut("y", modifiers: [.command, .control])
        .disabled(!isRunning)
        Button("Shut Down") { if let name { store.shutdown(name) } }
            .keyboardShortcut(".")
            .disabled(!isRunning)
        Button("Stop Now…") { if let name { VMDialog.stop(name).post() } }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(!isRunning)
    }
}

/// The VM's pages are in the View menu (⌘1–5); taking a snapshot is an action, so it stays here.
private struct TakeSnapshotItem: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?
    let isBusy: Bool

    var body: some View {
        Button("Take Snapshot") { if let name { store.takeSnapshot(of: name, named: Snapshots.defaultName()) } }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(vm == nil || isBusy)
    }
}

private struct LibraryItems: View {
    let name: String?
    let vm: VMItem?
    let isRunning: Bool

    var body: some View {
        Button("Clone…") { if let name { VMDialog.clone(name).post() } }
            .disabled(vm == nil || isRunning)
        Button("Rename…") { if let name { VMDialog.rename(name).post() } }
            .disabled(vm == nil || isRunning)
        Button("Export…") { if let name { VMDialog.export(name).post() } }
            .disabled(vm == nil || isRunning)
        Button("Save as Template…") { if let name { VMDialog.saveTemplate(name).post() } }
            .disabled(vm == nil)
        Button("Show in Finder") { if let vm { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) } }
            .disabled(vm == nil)
        Button("Delete…") { if let name { VMDialog.delete(name).post() } }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(vm == nil || isRunning)
    }
}

private struct NetworkModePicker: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?
    let isRunning: Bool

    var body: some View {
        Picker("Network", selection: mode) {
            ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
        }
        .disabled(vm == nil || isRunning)
    }

    private var mode: Binding<NetworkMode?> {
        Binding(
            get: { vm?.config.network.mode },
            set: { mode in
                if let name, let mode { store.update(name) { config in config.network.mode = mode } }
            }
        )
    }
}

private struct ISOMenu: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?
    let isBusy: Bool

    var body: some View {
        if vm?.config.os.supportsISO != false {
            Menu("ISO") {
                Button("Choose ISO…") {
                    if let name, let url = FilePanels.chooseISO(for: name) { store.changeISO(of: name, to: url) }
                }
                Button("Detach ISO") { if let name { store.changeISO(of: name, to: nil) } }
                    .disabled(vm?.config.isoPath == nil)
            }
            .disabled(vm?.canChangeISO != true || isBusy)
        }
    }
}

private struct USBMenu: View {
    let name: String?
    let vm: VMItem?
    let isHosted: Bool

    var body: some View {
        Menu("USB Devices") {
            if isHosted, let name {
                USBDeviceItems(name: name)
            } else {
                Text("Start the VM in Hangar to connect USB devices")
            }
        }
        .disabled(vm == nil)
    }
}

private struct SharedFoldersMenu: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?

    var body: some View {
        Menu("Shared Folders") {
            Button("Add Folder…") {
                if let name, let chosen = FilePanels.chooseSharedFolders(for: name) {
                    store.addSharedFolders(chosen.urls, readOnly: chosen.isReadOnly, to: name)
                }
            }
            if let vm, !vm.config.sharedFolders.isEmpty {
                Divider()
                ForEach(vm.config.sharedFolders, id: \.name) { folder in
                    Button("Stop Sharing “\(folder.name)”") {
                        store.updateSharedFolders(vm.name) { $0.removeAll { $0.name == folder.name } }
                    }
                }
            }
        }
        .disabled(vm == nil)
    }
}

private struct GuestOptionToggles: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let vm: VMItem?
    let isRunning: Bool

    var body: some View {
        Toggle("Use Shared Clipboard", isOn: setting(\.clipboard))
            .disabled(vm == nil || isRunning)
        if vm?.config.os.supportsAudio != false {
            Toggle("Audio Output", isOn: setting(\.audio))
                .disabled(vm == nil || isRunning)
        }
        if vm?.config.os.supportsRosetta == true {
            Toggle("Rosetta for x86-64 Programs", isOn: setting(\.rosetta))
                .disabled(isRunning)
        }
        if vm?.config.os.supportsNestedVirtualization == true, VMSettings.macSupportsNestedVirtualization {
            Toggle("Nested Virtualization", isOn: setting(\.usesNestedVirtualization))
                .disabled(isRunning)
        }
    }

    /// Off, and changing nothing, while no VM is selected.
    private func setting(_ keyPath: WritableKeyPath<VMConfig, Bool> & Sendable) -> Binding<Bool> {
        guard let vm else { return .constant(false) }
        return store.binding(keyPath, of: vm)
    }
}

/// An agent that answers is updated over `hangar exec`; any other is installed by hand with the steps Hangar shows.
/// While an update runs, the item cancels it, until the guest is finishing it on its own.
private struct GuestAgentItem: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let isRunning: Bool
    let isBusy: Bool

    var body: some View {
        if let name, let update = store.agentUpdates[name] {
            Button("Cancel Guest Agent Update") { store.cancelAgentUpdate(of: name) }
                .disabled(!update.canCancel)
        } else {
            InstallOrUpdateItem(name: name, isRunning: isRunning, isBusy: isBusy)
        }
    }
}

private struct InstallOrUpdateItem: View {
    @Environment(VMStore.self) private var store
    let name: String?
    let isRunning: Bool
    let isBusy: Bool

    var body: some View {
        let version = name.flatMap { store.usage[$0]?.agentVersion }
        let isCurrent = version.map { $0 >= GuestSetup.agentVersion } ?? false
        Button(version == nil ? "Install Guest Agent…" : isCurrent ? "Guest Agent Installed" : "Update Guest Agent…") {
            guard let name else { return }
            if GuestAgentUpdate.canUpdate(from: version) {
                store.updateAgent(name)
            } else {
                store.shareTools(with: name)
            }
        }
        .disabled(isCurrent || !isRunning || isBusy)
    }
}
