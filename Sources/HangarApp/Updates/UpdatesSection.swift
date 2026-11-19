import HangarKit
import HangarSupport
import SwiftUI

/// General Settings' Updates: the running version, whether a newer one is out, and automatic checks.
struct UpdatesSection: View {
    @Environment(AppUpdater.self) private var updater
    @AppStorage(AppUpdater.automaticChecksKey) private var checksAutomatically = true

    var body: some View {
        Section {
            LabeledContent("Hangar \(updater.runningVersion?.description ?? HangarVersion.current)") {
                if let action = UpdateAction(updater) {
                    Button(action.title, action: action.perform)
                        .disabled(!action.isEnabled)
                } else {
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(!updater.canUpdate || updater.isChecking)
                }
            }
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .disabled(!updater.canUpdate)
        } header: {
            Text("Updates")
        } footer: {
            Text(status)
        }
    }

    private var status: String {
        guard updater.canUpdate else { return "This build of Hangar isn't a release, so it doesn't update itself." }
        switch updater.state {
        case .idle, .available, .downloading, .ready:
            return "Hangar installs only versions that Baseguard signed and Apple notarized."
        case .checking:
            return "Checking GitHub for a newer Hangar…"
        case .upToDate:
            return "Hangar is up to date."
        case .failed(let message):
            return "Couldn't check for updates: \(message)"
        }
    }
}
