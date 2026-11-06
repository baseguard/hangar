import AppKit

enum AppFocus {
    static func show(_ open: () -> Void) {
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.activate(ignoringOtherApps: true)
        open()
        // SwiftUI makes the window after this returns, sometimes a frame later, so the new window is looked for twice.
        for delay in [0.0, 0.25] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                let opened = NSApp.windows.first {
                    $0.isVisible && $0.canBecomeKey && !before.contains(ObjectIdentifier($0))
                }
                guard
                    let window = opened ?? NSApp.keyWindow
                        ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey })
                else { return }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
