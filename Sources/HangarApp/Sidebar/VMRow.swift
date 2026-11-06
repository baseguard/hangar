import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct VMRow: View {
    let vm: VMItem
    var usage: VMUsage?
    var twin: String?

    var body: some View {
        HStack {
            OSBadge(os: vm.config.os)
            VStack(alignment: .leading) {
                Text(vm.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            if let twin {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Copied outside Hangar: it shares its identity with “\(twin)”")
                    .accessibilityLabel("Copied outside Hangar")
            }
            if vm.config.traffic.isolated {
                Image(systemName: "network.slash")
                    .foregroundStyle(.red)
                    .help("Isolated: only this Mac can reach it")
                    .accessibilityLabel("Isolated")
            } else if vm.config.traffic.enforces {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.secondary)
                    .help("Traffic rules: \(vm.config.traffic.mode.displayName)")
                    .accessibilityLabel("Traffic rules: \(vm.config.traffic.mode.displayName)")
            }
            PhaseIndicator(phase: vm.phase)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(vm.phase.title)
    }

    private var subtitle: String {
        switch vm.phase {
        case .running:
            let parts = [vm.ip ?? "Waiting for an address", usage?.cpuText(of: vm.config.cpuCount)]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .stopped, .paused, .busy, .failed:
            return vm.phase.title
        }
    }
}
