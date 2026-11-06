import SwiftUI

struct SymbolBadge: View {
    static let symbolScale: CGFloat = 0.48
    static let cornerScale: CGFloat = 0.28

    let systemImage: String
    let tint: Color
    var size = Metrics.controlSize

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * Self.symbolScale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * Self.cornerScale, style: .continuous))
            .accessibilityHidden(true)
    }
}
