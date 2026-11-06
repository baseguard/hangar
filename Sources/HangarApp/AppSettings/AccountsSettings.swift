import HangarKit
import HangarSupport
import SwiftUI

struct AccountsSettings: View {
    @Environment(VMStore.self) private var store
    @State private var signIns: [RegistryCredentials.SignIn] = []
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if signIns.isEmpty {
                    Text("No registries yet.").foregroundStyle(.secondary)
                }
                ForEach(signIns, id: \.self) { signIn in
                    LabeledContent {
                        Button("Sign Out") { signOut(signIn) }
                    } label: {
                        Text(signIn.registry)
                        Text(signIn.user)
                    }
                }
            } header: {
                Text("Registries")
            } footer: {
                Text(
                    "Hangar signs in to these to export VMs and to create VMs from private images. The tokens are kept in your Keychain; the hangar command uses them too."
                )
            }
            Section {
                Button("Add Registry…") { adding = true }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .sheet(isPresented: $adding, onDismiss: refresh) { AddRegistrySheet() }
    }

    /// The Keychain can take a while, or wait for the user, so it is never asked on the main actor.
    private func refresh() {
        Task {
            do {
                signIns = try await runInBackground { try RegistryCredentials.signIns() }
                problem = nil
            } catch {
                signIns = []
                problem = error.localizedDescription
            }
        }
    }

    private func signOut(_ signIn: RegistryCredentials.SignIn) {
        Task {
            do {
                try await runInBackground { try RegistryCredentials.remove(for: signIn.registry) }
            } catch {
                store.report(error, doing: "sign out of \(signIn.registry)")
            }
            refresh()
        }
    }
}

private struct AddRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var registry = ""
    @State private var user = ""
    @State private var token = ""
    @State private var problem: String?
    @State private var check: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Registry", text: $registry, prompt: Text("ghcr.io"))
                    TextField("User name", text: $user)
                    SecureField("Token", text: $token)
                } header: {
                    Text("Add a Registry")
                } footer: {
                    Text(
                        problem
                            ?? "For GitHub, a personal access token with read:packages, and write:packages to export.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if check != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") { check = Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(registry.isEmpty || user.isEmpty || token.isEmpty || check != nil)
            }
            .scenePadding()
        }
        .frame(width: SettingsView.width - Metrics.openSpacing * 2)
        // A sign-in the user walked away from must not be saved when its check comes back.
        .onDisappear { check?.cancel() }
    }

    private func signIn() async {
        defer { check = nil }
        let host = registry.trimmingCharacters(in: .whitespaces)
        let credentials = RegistryCredentials(
            user: user.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            try credentials.validate(for: host)
            try await credentials.check(at: host)
            try Task.checkCancellation()
            try credentials.save(for: host)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
