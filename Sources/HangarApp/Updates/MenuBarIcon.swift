import AppKit
import SwiftUI

/// The menu bar item's icon: filled while a VM runs, with a dot while an update waits.
struct MenuBarIcon: View {
    let isRunning: Bool
    let hasUpdate: Bool

    private var symbolName: String {
        isRunning ? "square.3.layers.3d.top.filled" : "square.3.layers.3d"
    }

    var body: some View {
        if hasUpdate, let image = Self.withBadge(symbolName) {
            Image(nsImage: image)
        } else {
            Image(systemName: symbolName)
        }
    }

    /// The menu bar shows only an image, so the dot is drawn into it. The symbol takes the menu bar's own text color
    /// at each drawing, as a template image would; the dot keeps its color.
    private static func withBadge(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        guard
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Hangar, update available")?
                .withSymbolConfiguration(configuration)
        else { return nil }

        let badgeSize = symbol.size.height * 0.4
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))?.draw(in: rect)
            let badge = NSRect(x: rect.maxX - badgeSize, y: rect.maxY - badgeSize, width: badgeSize, height: badgeSize)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
            return true
        }
        image.accessibilityDescription = symbol.accessibilityDescription
        return image
    }
}
