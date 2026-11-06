import SwiftUI

struct PhaseIndicator: View {
    let phase: VMPhase

    var body: some View {
        Group {
            switch phase {
            case .running: Circle().fill(.green).frame(width: Metrics.indicatorSize, height: Metrics.indicatorSize)
            case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.yellow)
            case .busy: ProgressView().controlSize(.mini)
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .stopped: EmptyView()
            }
        }
        .help(phase.title)
        .accessibilityLabel(phase.title)
    }
}
