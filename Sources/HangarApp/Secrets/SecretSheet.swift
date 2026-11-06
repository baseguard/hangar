import HangarKit
import HangarSecrets
import SwiftUI

/// Adds a secret, or changes one; a changed secret keeps its value unless a new one is typed.
struct SecretSheet: View {
    enum Mode: Identifiable {
        case adding
        case editing(SecretRule)

        var id: String {
            switch self {
            case .adding: "adding"
            case .editing(let rule): rule.name
            }
        }
    }

    @Environment(VMStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let vmName: String
    let mode: Mode
    /// The VM's secrets already: adding one of these would replace it without saying so.
    let takenNames: [String]
    /// A secret from a template that was never given a value: editing it must give one.
    var needsValue = false

    @State private var name = ""
    @State private var hosts = ""
    @State private var value = ""
    /// Empty sets no header: the placeholder only becomes the value where the VM's programs send it.
    @State private var headerName = "Authorization"
    @State private var headerPrefix = "Bearer"
    /// What a header set with `hangar secret` has after the token; kept as it is, never shown.
    @State private var headerSuffix = ""
    @State private var problem: String?
    @State private var saving: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SecretFields(
                    hosts: $hosts, name: $name, headerName: $headerName, headerPrefix: $headerPrefix, value: $value,
                    isEditing: isEditing, keepsValue: keepsValue, problem: problem ?? takenNameProblem)
            }
            .formStyle(.grouped)
            HStack {
                if saving != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Secret") { saving = Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || saving != nil)
            }
            .scenePadding()
        }
        .frame(width: SettingsView.width)
        .onAppear(perform: fill)
    }

    private var isEditing: Bool {
        if case .editing = mode { return true }
        return false
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !hostList.isEmpty && (keepsValue || !value.isEmpty) && takenNameProblem == nil
    }

    private var keepsValue: Bool { isEditing && !needsValue }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var takenNameProblem: String? {
        guard !isEditing, takenNames.contains(trimmedName) else { return nil }
        return "\(vmName) already has a secret named \(trimmedName); edit it instead."
    }

    private var hostList: [String] {
        hosts.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private func fill() {
        guard case .editing(let rule) = mode else { return }
        name = rule.name
        hosts = rule.hosts.joined(separator: ", ")
        headerName = ""
        headerPrefix = ""
        if let ruleHeader = rule.header {
            let parts = ruleHeader.format.components(separatedBy: SecretRule.valueMarker)
            headerName = ruleHeader.name
            headerPrefix = parts[0].trimmingCharacters(in: .whitespaces)
            headerSuffix = parts.count > 1 ? parts[1] : ""
        }
    }

    private func save() async {
        defer { saving = nil }
        do {
            let rule = SecretRule(name: trimmedName, hosts: hostList, header: ruleHeader())
            try await store.saveSecret(rule, value: value.isEmpty ? nil : value, in: vmName)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func ruleHeader() -> SecretRule.Header? {
        let name = headerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let prefix = headerPrefix.trimmingCharacters(in: .whitespaces)
        let format = (prefix.isEmpty ? "" : prefix + " ") + SecretRule.valueMarker + headerSuffix
        return SecretRule.Header(name: name, format: format)
    }
}

private struct SecretFields: View {
    @Binding var hosts: String
    @Binding var name: String
    @Binding var headerName: String
    @Binding var headerPrefix: String
    @Binding var value: String
    let isEditing: Bool
    let keepsValue: Bool
    let problem: String?

    var body: some View {
        Section {
            TextField("Hosts", text: $hosts, prompt: Text("api.github.com"))
            TextField("Name", text: $name, prompt: Text("GITHUB_TOKEN"))
                .disabled(isEditing)
            TextField("Header", text: $headerName, prompt: Text("None"))
            TextField("Prefix", text: $headerPrefix, prompt: Text("None"))
                .disabled(headerName.trimmingCharacters(in: .whitespaces).isEmpty)
            SecureField("Value", text: $value, prompt: Text(keepsValue ? "Keep the saved value" : "Required"))
        } header: {
            Text(isEditing ? "Change the Secret" : "Add a Secret")
        } footer: {
            Text(problem ?? explanation)
                .foregroundStyle(problem == nil ? Color.secondary : Color.red)
        }
    }

    private var explanation: String {
        let rules =
            "Separate several hosts with commas. The name is the variable the VM's programs see, holding a placeholder that becomes the value in any header it is in, never in a URL or a body. The value goes to your Keychain only."
        guard let preview else { return rules }
        return "Every request to these hosts gets “\(preview)”. " + rules
    }

    private var preview: String? {
        let header = headerName.trimmingCharacters(in: .whitespaces)
        guard !header.isEmpty else { return nil }
        let prefix = headerPrefix.trimmingCharacters(in: .whitespaces)
        return "\(header): " + (prefix.isEmpty ? "" : prefix + " ") + "••••"
    }
}
