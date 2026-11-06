import HangarKit
import HangarSecrets
import SwiftUI

extension VMStore {
    /// `value` is `nil` when an existing secret keeps its value.
    func saveSecret(_ rule: SecretRule, value: String?, in name: String) async throws {
        let bundle = try VMLibrary.bundle(named: name)
        try await runInBackground { _ = try VMSecrets.set(rule, value: value, in: bundle) }
        refresh()
        await applySecrets(to: name)
    }

    func removeSecret(_ secret: String, from name: String) {
        Task {
            do {
                let bundle = try VMLibrary.bundle(named: name)
                try await runInBackground { try VMSecrets.remove(secret, from: bundle) }
                refresh()
                await applySecrets(to: name)
            } catch {
                report(error, doing: "remove the secret \(secret)")
            }
        }
    }

    private func applySecrets(to name: String) async {
        do {
            try await send(.reloadSecrets, to: name)
        } catch {
            report(error, doing: "give \(name) its secrets")
        }
    }
}
