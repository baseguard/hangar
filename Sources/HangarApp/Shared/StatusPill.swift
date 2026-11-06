import SwiftUI

struct StatusPill: View {
    let phase: VMPhase

    var body: some View {
        HStack {
            if case .busy = phase {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(phase.color).frame(width: Metrics.indicatorSize, height: Metrics.indicatorSize)
            }
            Text(phase.title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Metrics.miniControlInset)
        .frame(height: Metrics.miniControlSize)
        .background(phase.color.opacity(Metrics.pillTint), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
