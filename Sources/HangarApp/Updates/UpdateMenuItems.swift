import SwiftUI

/// The Hangar menu's Check for Updates, which answers even when Hangar is up to date.
struct CheckForUpdatesButton: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        Button("Check for Updates…") {
            Task {
                await updater.check()
                onMainRunLoop { UpdateAlerts.showResult(of: updater) }
            }
        }
        .disabled(!updater.canUpdate || updater.isChecking)
    }
}

/// The menu bar item's first entry while a newer Hangar is out, downloading or waiting to install.
struct UpdateMenuItem: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        if let action = UpdateAction(updater) {
            Button(action.title, systemImage: "arrow.down.circle.fill", action: action.perform)
                .disabled(!action.isEnabled)
            Divider()
        }
    }
}
