import SwiftUI

/// Sizes follow the HIG's 8-point grid and AppKit's control sizes (large 28, regular 24, small 20, mini 16 points
/// high, with their insets); the opacities are Hangar's own, kept here so views agree.
enum Metrics {
    static let spacing: CGFloat = 8
    static let bezelSpacing: CGFloat = 12
    static let openSpacing: CGFloat = 24

    static let cornerRadius: CGFloat = 12

    static let controlSize: CGFloat = 28
    static let controlInset: CGFloat = 14
    static let regularControlSize: CGFloat = 24
    static let regularControlInset: CGFloat = 12
    static let smallControlSize: CGFloat = 20
    static let smallControlInset: CGFloat = 7
    static let miniControlSize: CGFloat = 16
    static let miniControlInset: CGFloat = 6
    static let extraLargeControlSize: CGFloat = 36

    static let indicatorSize: CGFloat = spacing
    static let lineWidth: CGFloat = 2
    static let hairline: CGFloat = 1
    static let chartHeight: CGFloat = controlSize * 2

    nonisolated static let detailsWidth: CGFloat = 270

    static let iconSize: CGFloat = 64
    /// Finder's list view and a table row show 16-point icons, NSImage's small icon size.
    static let listIconSize: CGFloat = 16
    static let appIconSize: CGFloat = 128

    /// Tints behind pills and banners, and dimming for disabled, pressed and overlaid content.
    static let pillTint = 0.14
    static let bannerTint = 0.07
    static let disabledOpacity = 0.5
    static let pressedDim = 0.2
    static let dividerOnTint = 0.35
    static let iconOnDark = 0.9
    static let captionOnDark = 0.25
    static let chartArea = 0.15
    static let chartRule = 0.5
}
