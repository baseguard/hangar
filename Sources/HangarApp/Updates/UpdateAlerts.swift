import AppKit
import HangarKit

/// The questions and answers about updating, as alerts that bring Hangar forward even from the menu bar.
@MainActor
enum UpdateAlerts {
    /// The answer to Check for Updates, which the user waits for.
    static func showResult(of updater: AppUpdater) {
        switch updater.state {
        case .available(let release):
            if askToDownload(release, running: updater.runningVersion) { updater.download() }
        case .upToDate:
            inform("Hangar \(updater.runningVersion?.description ?? "") is the latest version.")
        case .failed(let message):
            inform("Couldn't check for updates", details: message)
        case .idle, .checking, .downloading, .ready:
            break
        }
    }

    static func askToDownload(_ release: AppRelease, running: AppVersion?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hangar \(release.version) is available."
        alert.informativeText =
            "You have \(running?.description ?? "an older version"). Hangar downloads it, checks that Baseguard signed it, and asks before it relaunches."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch run(alert) {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.notesURL)
            return false
        default:
            return false
        }
    }

    static func askToRelaunch(for release: AppRelease) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hangar \(release.version) is ready to install."
        alert.informativeText =
            "Relaunching shuts down the VMs running in Hangar. VMs started in the background or from the command line keep running this version until you start them again. Later installs it when you quit Hangar."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        return run(alert) == .alertFirstButtonReturn
    }

    private static func inform(_ message: String, details: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        _ = run(alert)
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
