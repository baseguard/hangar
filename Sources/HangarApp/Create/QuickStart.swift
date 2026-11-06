import HangarKit
import SwiftUI

struct QuickStart: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let kind: CreateVMView.Kind
    @Binding var pick: CreateVMView.Choice
    let close: () -> Void
    let created: (UUID) -> Void
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            form
                .frame(height: CreateForm.formHeight)
            Divider()
            CreateFormFooter(problem: validationMessage, createTitle: "Create and Start", close: close, create: create)
        }
        .onAppear { if name.isEmpty { name = store.uniqueName(pick.baseName) } }
        .onChange(of: pick) { old, new in
            if name.isEmpty || name == store.uniqueName(old.baseName) { name = store.uniqueName(new.baseName) }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(pick.baseName))
                Picker("Start from", selection: $pick) {
                    ForEach(kind.quickChoices) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(pick.summary)
            }
            ImageAccountSection(
                footer:
                    "Every Quick Start VM gets this administrator, and SSH is on. Anyone who can reach the VM can sign in with this password, so change it in the VM."
            )
        }
        .formStyle(.grouped)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var validationMessage: String? {
        if let problem = store.nameProblem(trimmedName) { return problem }
        return nil
    }

    private func create() {
        guard validationMessage == nil else { return }
        let os = pick.kind.os ?? .linux
        let options = CreateOptions(
            cpuCount: os.defaultCPUCount, memorySize: os.defaultMemorySize,
            diskSize: os.defaultDiskSize, network: .managed)
        let source: VMSource
        if let image = pick.linuxImage {
            source = .linuxCloudImage(
                image, account: CloudInitAccount(username: MacImage.user, password: MacImage.password), userData: nil)
        } else if let image = pick.macImage {
            source = .macImage(image, account: nil)
        } else {
            return
        }

        let open = openWindow
        let job = store.create(name: trimmedName, source: source, options: options) {
            open(id: DisplayWindow.id, value: $0)
        }
        created(job)
    }
}
