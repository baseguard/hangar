import HangarKit
import HangarSupport

/// What the update badges in the menu bar, the sidebar and Settings offer, by how far the update has come.
@MainActor
struct UpdateAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void

    init?(_ updater: AppUpdater) {
        switch updater.state {
        case .available(let release):
            title = "Update to Hangar \(release.version)…"
            isEnabled = true
            perform = { if UpdateAlerts.askToDownload(release, running: updater.runningVersion) { updater.download() } }
        case .downloading(let release, let progress):
            title = "Downloading Hangar \(release.version)…" + Self.percent(progress)
            isEnabled = false
            perform = {}
        case .ready(let release, _):
            title = "Relaunch to Update to Hangar \(release.version)"
            isEnabled = true
            perform = { updater.relaunchToUpdate() }
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    private static func percent(_ progress: CreationProgress?) -> String {
        guard let fraction = progress?.fraction else { return "" }
        return " \(Int(fraction * 100))%"
    }
}
