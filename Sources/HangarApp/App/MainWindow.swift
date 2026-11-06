import AppKit
import SwiftUI

enum MainWindow {
    static let id = "main"
    /// Kept from the last window that appeared: the menu bar item has no scene of its own to open windows from.
    static var open: OpenWindowAction?

    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.id }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(id: MainWindow.id)
        }
        NSApp.activate()
    }
}
