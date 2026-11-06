import AppKit

/// With the Dock icon off, Hangar lives in the menu bar, and macOS gives such an app no menu bar of its own. While one
/// of its windows is open it is an ordinary app again, so the Virtual Machine menu and the others are there.
enum DockIcon {
    static let visibilityKey = "showDockIcon"

    private static var windowObservers: [NotificationCenter.ObservationToken] = []

    static var isShown: Bool {
        let defaults = UserDefaults.standard
        let dock = defaults.object(forKey: visibilityKey) as? Bool ?? true
        let menuBar = defaults.object(forKey: MenuBarMenu.visibilityKey) as? Bool ?? true
        return dock || !menuBar
    }

    /// Hidden with ⌘H isn't closed: Hangar keeps its place in the Dock and ⌘Tab until it is shown again.
    static func apply() {
        guard !NSApp.isHidden else { return }
        let policy: NSApplication.ActivationPolicy = isShown || hasOpenWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }

        NSApp.setActivationPolicy(policy)
        // The menu bar changes over only once the app is activated again; an app in the background waits for the user.
        if policy == .regular, NSApp.isActive { NSApp.activate() }
    }

    static func settingChanged() {
        apply()
        NSApp.activate()
    }

    static func followWindows() {
        let center = NotificationCenter.default
        // A window opened in the background may be hidden behind others and change nothing until the user brings
        // Hangar forward.
        windowObservers = [
            center.addObserver(of: NSApplication.self, for: .didBecomeActive) { _ in apply() },
            center.addObserver(of: NSWindow.self, for: .didBecomeKey) { _ in apply() },
            center.addObserver(of: NSWindow.self, for: .didChangeOcclusionState) { _ in apply() },
            // A closing window is still on screen while this is sent.
            center.addObserver(of: NSWindow.self, for: .willClose) { _ in Task { apply() } },
        ]
    }

    /// A minimized window counts, since only the Dock brings it back; alerts, sheets and the menu bar item's menu don't.
    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }
}
