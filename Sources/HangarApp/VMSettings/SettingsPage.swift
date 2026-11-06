import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct SettingsPage: View {
    static let popoverWidth: CGFloat = 300
    static let readableWidth: CGFloat = 760

    @Environment(VMStore.self) private var store
    let vm: VMItem

    @State private var width: CGFloat = 0

    var body: some View {
        Form {
            if vm.isRunning {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Notice(text: "Shut down \(vm.name) to change the dimmed settings.", systemImage: "lock.fill")
                        Spacer()
                        Button("Shut Down") { store.shutdown(vm.name) }
                            .controlSize(.small)
                    }
                }
            }
            GeneralSection(vm: vm)
            HardwareSection(vm: vm)
            NetworkSection(vm: vm)
            SharingSection(vm: vm)
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, max(0, (width - Self.readableWidth) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
}

private struct GeneralSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @State private var name = ""
    @State private var sshUser = ""

    var body: some View {
        Section("General") {
            TextField("Name", text: $name)
                .disabled(vm.isRunning)
                .onSubmit(save)
            TextField("Default user", text: $sshUser, prompt: Text("admin"))
                .onSubmit(save)
                .help("Used to sign in over SSH and Remote Desktop")
            Toggle("Start when Hangar opens", isOn: store.binding(\.autoStart, of: vm))
            if nameChanged || userChanged {
                HStack {
                    if let problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(problem != nil)
                }
            }
        }
        .onAppear {
            name = vm.name
            sshUser = vm.config.sshUser ?? ""
        }
        .onChange(of: vm.config.sshUser) { sshUser = vm.config.sshUser ?? "" }
    }

    private var newName: String { name.trimmingCharacters(in: .whitespaces) }
    private var newUser: String { sshUser.trimmingCharacters(in: .whitespaces) }
    private var nameChanged: Bool { newName != vm.name }
    private var userChanged: Bool { newUser != (vm.config.sshUser ?? "") }

    private var problem: String? {
        if nameChanged, let problem = store.nameProblem(newName, ignoring: vm.name) { return problem }
        if userChanged, !newUser.isEmpty, !VMConfig.isValidUserName(newUser) {
            return "User names use letters, digits, “.”, “_” and “-”, and don't start with “-”."
        }
        return nil
    }

    private func save() {
        guard problem == nil else { return }
        if userChanged {
            let user = newUser
            store.update(vm.name) { config in config.sshUser = user.isEmpty ? nil : user }
        }
        if nameChanged {
            let old = vm.name
            let renamed = newName
            Task {
                if await store.rename(old, to: renamed) {
                    store.ask(.page(vm: renamed, page: .settings))
                } else {
                    name = old
                }
            }
        }
    }
}

private struct HardwareSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @State private var growingDisk = false

    var body: some View {
        Section {
            StepperRow(
                title: "Processors", value: "\(vm.config.cpuCount)", number: store.binding(\.cpuCount, of: vm),
                range: 1...ProcessInfo.processInfo.activeProcessorCount)
            StepperRow(
                title: "Memory", value: ByteSize.format(vm.config.memorySize), number: memoryGB,
                range: 1...max(1, Int(ProcessInfo.processInfo.physicalMemory / ByteSize.gib)))
            LabeledContent("Disk") {
                HStack {
                    Text(ByteSize.format(vm.diskSize)).monospacedDigit()
                    Button("Grow…") { growingDisk = true }
                        .controlSize(.small)
                        .popover(isPresented: $growingDisk, arrowEdge: .leading) {
                            GrowDiskPopover(vm: vm) { growingDisk = false }
                        }
                }
            }
            if vm.config.os == .windows {
                LabeledContent("Display", value: "\(WindowsPlatform.display.width) × \(WindowsPlatform.display.height)")
            } else {
                Picker("Display", selection: display) {
                    ForEach(displayChoices, id: \.self) { choice in
                        Text(choice.replacingOccurrences(of: "x", with: " × ")).tag(choice)
                    }
                }
            }
        } header: {
            Text("Hardware")
        } footer: {
            if vm.config.os == .windows {
                Text(
                    "Windows' display driver works up to \(WindowsPlatform.display.width) × \(WindowsPlatform.display.height) here; Remote Desktop works at any size."
                )
            }
        }
        .disabled(vm.isRunning)
    }

    private var memoryGB: Binding<Int> {
        Binding(
            get: { Int(vm.config.memorySize / ByteSize.gib) },
            set: { value in store.update(vm.name) { config in config.memorySize = UInt64(value) * ByteSize.gib } }
        )
    }

    /// Common Mac and monitor sizes; a VM with another keeps it at the top of the list.
    private static let displayPresets = [
        "1280x800", "1440x900", "1920x1080", "1920x1200", "2560x1440", "2560x1600", "3024x1964", "3840x2160",
    ]

    private var displayChoices: [String] {
        let current = "\(vm.config.display.width)x\(vm.config.display.height)"
        return Self.displayPresets.contains(current) ? Self.displayPresets : [current] + Self.displayPresets
    }

    private var display: Binding<String> {
        Binding(
            get: { "\(vm.config.display.width)x\(vm.config.display.height)" },
            set: { value in
                let parts = value.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                store.update(vm.name) { config in
                    config.display.width = parts[0]
                    config.display.height = parts[1]
                }
            }
        )
    }
}

private struct GrowDiskPopover: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let close: () -> Void
    @State private var diskGB = 0
    /// Past any Mac's disk; the stepper starts a little above the current size.
    private static let largestDiskGB = 65_536
    private static let suggestedGrowthGB = 16
    private static let stepGB = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            Text("Grow the Disk").font(.headline)
            Stepper(value: $diskGB, in: currentDiskGB...max(currentDiskGB, Self.largestDiskGB), step: Self.stepGB) {
                Text("\(diskGB) GB").monospacedDigit()
            }
            Text("Disks can only grow. Grow the partition inside the guest afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Grow to \(diskGB) GB") {
                    store.growDisk(vm.name, to: UInt64(diskGB) * ByteSize.gib)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(diskGB <= currentDiskGB)
            }
        }
        .padding()
        .frame(width: SettingsPage.popoverWidth)
        .onAppear { diskGB = currentDiskGB + Self.suggestedGrowthGB }
    }

    private var currentDiskGB: Int {
        Int((vm.diskSize + ByteSize.gib - 1) / ByteSize.gib)
    }
}

private struct NetworkSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @State private var confirmingMAC = false

    var body: some View {
        Section("Network") {
            // Only what can't change while the VM runs is turned off, so the addresses can still be copied.
            Picker("Network", selection: store.binding(\.network.mode, of: vm)) {
                ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .disabled(vm.isRunning)
            LabeledContent("MAC address") { CopyableText(vm.config.network.macAddress) }
            if let reserved = vm.config.network.ipAddress, vm.config.network.mode == .managed {
                LabeledContent("Reserved address") { CopyableText(reserved) }
            }
            Button("New MAC Address…") { confirmingMAC = true }
                .confirmationDialog("Give \(vm.name) a new MAC address?", isPresented: $confirmingMAC) {
                    Button("New MAC Address") {
                        store.update(vm.name) { config in config.network.macAddress = VMConfig.randomMACAddress() }
                    }
                } message: {
                    Text("The guest sees a new network card. Some guests then need their network set up again.")
                }
                .disabled(vm.isRunning)
        }
    }
}

private struct SharingSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        Section {
            ForEach(vm.config.sharedFolders) { folder in
                SharedFolderRow(vm: vm, folder: folder)
            }
            Button("Add Folder…") {
                if let chosen = FilePanels.chooseSharedFolders(for: vm.name) {
                    store.addSharedFolders(chosen.urls, readOnly: chosen.isReadOnly, to: vm.name)
                }
            }
        } header: {
            Text("Shared Folders")
        } footer: {
            Text(hint)
        }
    }

    private var hint: String {
        switch vm.config.os {
        case .macOS: "The guest sees them in /Volumes/My Shared Files."
        case .linux: "The guest sees them in /mnt/hangar, mounted by Hangar's agent."
        case .windows: "Windows shows them on drive Z:."
        }
    }
}

private struct SharedFolderRow: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let folder: SharedFolder

    var body: some View {
        HStack {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(folder.name)
                Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("Read-only", isOn: readOnly)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Button {
                store.updateSharedFolders(vm.name) { $0.removeAll { $0.name == folder.name } }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).minimumHitArea()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop sharing \(folder.name)")
        }
    }

    private var readOnly: Binding<Bool> {
        Binding(
            get: { folder.readOnly },
            set: { value in
                store.updateSharedFolders(vm.name) { folders in
                    guard let index = folders.firstIndex(where: { $0.name == folder.name }) else {
                        return
                    }
                    folders[index].readOnly = value
                    try folders[index].checkSafe()
                }
            }
        )
    }
}
