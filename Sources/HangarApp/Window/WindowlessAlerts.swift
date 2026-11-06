import AppKit

/// An error from the menu bar item, or while every window is closed, has no window to show it, so it comes up
/// on its own as an app-modal alert (HIG).
enum WindowlessAlerts {
    static func showIfNoWindow(for store: VMStore) {
        // One alert at a time: the run loop of a showing one runs this again for a later report.
        guard !hasWindowForAlerts, NSApp.modalWindow == nil, let alert = store.alert else { return }

        let panel = NSAlert()
        panel.messageText = alert.title
        panel.informativeText = alert.message
        NSApp.activate()
        panel.runModal()
        store.dismissAlert(alert.id)

        showIfNoWindow(for: store)
    }

    /// The main, display and Settings windows show the store's alerts themselves.
    private static var hasWindowForAlerts: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}
