import HangarKit
import HangarTraffic
import SwiftUI

struct TrafficModeBadge: View {
    let policy: TrafficPolicy
    let network: NetworkMode

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Metrics.smallControlInset)
            .frame(height: Metrics.smallControlSize)
            .background(tint.opacity(Metrics.pillTint), in: .capsule)
            .foregroundStyle(tint)
    }

    private var title: String {
        if network != .managed { return "Not watched" }
        if policy.isolated { return "Isolated" }
        return policy.mode == .off ? "Not watched" : policy.mode.displayName
    }

    private var symbol: String {
        if network != .managed || policy.mode == .off { return "eye.slash" }
        if policy.isolated { return "network.slash" }
        return policy.enforces ? "checkmark.shield.fill" : "eye"
    }

    private var tint: Color {
        if network != .managed || policy.mode == .off { return .secondary }
        if policy.isolated { return .red }
        return policy.enforces ? .blue : .green
    }
}
