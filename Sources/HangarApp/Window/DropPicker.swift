import HangarSupport
import SwiftUI

/// Asks which running VM gets the files shared to Hangar; its only action is the same drop as dragging onto a VM's
/// window. It stays open while they copy, since the progress is otherwise only in that VM's own window.
struct DropPicker: View {
    @Environment(VMStore.self) private var store
    let request: DropRequest
    let close: () -> Void
    @State private var vm: String?
    @State private var droppedInto: String?

    var body: some View {
        if let droppedInto {
            DropProgress(vm: droppedInto, close: close)
        } else {
            DropChoice(request: request, vm: $vm, drop: drop, cancel: close)
        }
    }

    private func drop() {
        guard let vm, store.dropFiles(request.files, into: vm) else { return }
        droppedInto = vm
    }
}

private struct DropChoice: View {
    @Environment(VMStore.self) private var store
    let request: DropRequest
    @Binding var vm: String?
    let drop: () -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            Section {
                vmChoices
            } header: {
                Text(title)
            } footer: {
                Text("The files land in HangarDrop in the VM user's home folder.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: runningVMs, initial: true) { keepChoiceRunning() }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Drop", action: drop)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(vm == nil)
        }
        .scenePadding()
    }

    @ContentBuilder
    private var vmChoices: some View {
        if !store.hasScanned {
            ProgressView().controlSize(.small)
        } else if runningVMs.isEmpty {
            Text("No VM is running. Start one to drop the files into it.")
        } else {
            Picker("VM", selection: $vm) {
                ForEach(runningVMs, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    /// Only a running VM can take the files.
    private var runningVMs: [String] {
        store.vms.filter(\.isRunning).map(\.name)
    }

    /// A VM that stops can't be the choice any more; when only one VM runs, it is chosen for the user.
    private func keepChoiceRunning() {
        if let vm, runningVMs.contains(vm) { return }
        vm = runningVMs.count == 1 ? runningVMs.first : nil
    }

    private var title: String {
        request.files.count == 1
            ? "Drop “\(request.files[0].lastPathComponent)” into a VM" : "Drop \(request.files.count) items into a VM"
    }
}

/// Shows the copy until it ends, then where the files went. A failed or cancelled copy clears that note and the
/// picker closes with it; a failure has its own alert.
private struct DropProgress: View {
    @Environment(VMStore.self) private var store
    let vm: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            Text(store.dropStatus[vm] ?? "Copying to “\(vm)”…")
                .font(.headline)
            if isCopying {
                progress
            }
            HStack {
                Spacer()
                if isCopying {
                    Button("Cancel", role: .cancel) { store.cancelCopy(into: vm) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .scenePadding()
        .onChange(of: store.dropStatus[vm]) {
            if store.dropStatus[vm] == nil, !isCopying { close() }
        }
    }

    private var isCopying: Bool { store.isCopying(into: vm) }

    @ContentBuilder
    private var progress: some View {
        if let copy = store.copies[vm] {
            ProgressView(value: copy.fraction)
            Text("\(ByteSize.format(copy.copied)) of \(ByteSize.format(copy.total))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
