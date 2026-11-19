import HangarKit
import SwiftUI

/// At the foot of the sidebar while a newer Hangar is out, downloading or waiting to install.
struct UpdateBanner: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        if let action = UpdateAction(updater) {
            Button(action: action.perform) {
                Label(action.title, systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!action.isEnabled)
            .padding(Metrics.spacing)
        }
    }
}
