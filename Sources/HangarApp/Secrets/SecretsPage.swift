import HangarKit
import HangarSecrets
import SwiftUI

/// A VM's secrets: tokens its programs use without holding them. Values stay in the Keychain and are never shown.
struct SecretsPage: View {
    let vm: VMItem

    @State private var editing: SecretSheet.Mode?
    @State private var removing: SecretRule?
    /// `nil` until the Keychain is asked, so no secret shows as missing its value meanwhile.
    @State private var namesWithValues: Set<String>?
    /// Why the Keychain couldn't say which secrets have a value; shown instead of guessing.
    @State private var keychainProblem: String?

    var body: some View {
        Group {
            if rules.isEmpty {
                if isManaged {
                    NoSecretsView(add: { editing = .adding })
                } else {
                    NeedsManagedNetworkView()
                }
            } else {
                SecretList(
                    vm: vm, rules: rules, canChange: isManaged, keychainProblem: keychainProblem, hasValue: hasValue,
                    edit: { editing = .editing($0) }, remove: { removing = $0 }
                ) {
                    editing = .adding
                }
            }
        }
        .sheet(item: $editing) { mode in
            SecretSheet(vmName: vm.name, mode: mode, takenNames: rules.map(\.name), needsValue: needsValue(mode))
        }
        .task(id: vm.config.secrets) { await findValues() }
        .modifier(RemoveSecretConfirmation(vmName: vm.name, removing: $removing))
    }

    private var rules: [SecretRule] { vm.config.secrets?.rules ?? [] }

    private func hasValue(_ rule: SecretRule) -> Bool {
        namesWithValues?.contains(rule.name) ?? true
    }

    private func needsValue(_ mode: SecretSheet.Mode) -> Bool {
        guard case .editing(let rule) = mode else { return false }
        return !hasValue(rule)
    }

    private func findValues() async {
        guard let settings = vm.config.secrets else { return }
        do {
            namesWithValues = try await runInBackground { try SecretValues.namesWithValues(in: settings) }
            keychainProblem = nil
        } catch {
            keychainProblem = "Your Keychain didn't say which secrets have a value: \(error.localizedDescription)"
        }
    }

    /// Secrets are added and changed only on Hangar's managed network; removing them works on any network.
    private var isManaged: Bool { vm.config.network.mode == .managed }
}

private struct NeedsManagedNetworkView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Secrets Need Hangar's Network", systemImage: "key.slash")
        } description: {
            Text(
                "Hangar puts secrets in from outside the VM, which it can do only on Hangar Managed networking. Change the network in Settings."
            )
        }
    }
}

private struct NoSecretsView: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Secrets", systemImage: "key")
        } description: {
            Text(
                "A secret is a token the VM's programs use but never see. They get a placeholder, and Hangar puts the real value in on the way to the hosts you allow."
            )
        } actions: {
            Button("Add Secret…", action: add)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct SecretList: View {
    let vm: VMItem
    let rules: [SecretRule]
    let canChange: Bool
    let keychainProblem: String?
    let hasValue: (SecretRule) -> Bool
    let edit: (SecretRule) -> Void
    let remove: (SecretRule) -> Void
    let add: () -> Void

    var body: some View {
        List {
            if let keychainProblem {
                Label(keychainProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(rules, id: \.name) { rule in
                    SecretRow(
                        rule: rule, hasValue: hasValue(rule), canEdit: canChange, edit: { edit(rule) },
                        remove: { remove(rule) }
                    )
                    .contextMenu {
                        Button("Edit…") { edit(rule) }
                            .disabled(!canChange)
                        Button("Copy Placeholder") { Pasteboard.copy(rule.placeholder) }
                        Divider()
                        Button("Remove…", role: .destructive) { remove(rule) }
                    }
                }
            } header: {
                HStack {
                    Text("\(rules.count) Secret\(rules.count == 1 ? "" : "s")")
                        .font(.headline)
                    Spacer()
                    Button("Add Secret…", action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canChange)
                }
            } footer: {
                Text(footer)
                    .font(.callout.weight(.regular))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var footer: String {
        guard canChange else {
            return
                "Secrets work only on Hangar Managed networking, so this VM's are not used now. Change the network in Settings to use them again, or remove them."
        }
        let base =
            "Programs in the VM see each secret's variable set to its placeholder. Values stay in your Keychain; a running VM gets changes at once."
        return vm.config.os == .macOS
            ? base + " macOS asks for a password in the VM once, to trust Hangar's certificate authority." : base
    }
}

private struct SecretRow: View {
    let rule: SecretRule
    let hasValue: Bool
    let canEdit: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            SymbolBadge(systemImage: "key.fill", tint: .orange)
            VStack(alignment: .leading) {
                Text(rule.name).fontWeight(.medium).monospaced()
                Text("\(rule.hosts.joined(separator: ", ")) · \(places)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasValue {
                    CopyableText(rule.placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "No value yet, so the VM doesn't get this secret. Edit it to give one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Edit…", action: edit)
                .disabled(!canEdit)
            Button(action: remove) {
                Image(systemName: "trash").minimumHitArea()
            }
            .buttonStyle(.borderless)
            .help("Remove this secret")
            .accessibilityLabel("Remove \(rule.name)")
        }
    }

    private var places: String {
        var places = ["headers"]
        if let header = rule.header { places.append("sets \(header.name)") }
        return places.joined(separator: ", ")
    }
}

private struct RemoveSecretConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    let vmName: String
    @Binding var removing: SecretRule?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove the secret “\(removing?.name ?? "")”?",
            isPresented: isPresented($removing),
            titleVisibility: .visible, presenting: removing
        ) { rule in
            Button("Remove", role: .destructive) { store.removeSecret(rule.name, from: vmName) }
        } message: { _ in
            Text("Its value is deleted from your Keychain, and the VM no longer has the variable.")
        }
    }
}
