import HangarKit
import HangarSupport
import SwiftUI

struct ResourcesCard: View {
    let vm: VMItem
    let edit: () -> Void

    var body: some View {
        Card(title: "Resources", systemImage: "cpu") {
            VStack(spacing: Metrics.bezelSpacing) {
                Fact(title: "Processors", value: "\(vm.config.cpuCount)")
                Fact(title: "Memory", value: ByteSize.format(vm.config.memorySize))
                Fact(title: "Display", value: "\(vm.config.guestDisplay.width) × \(vm.config.guestDisplay.height)")
                Fact(title: "Network", value: vm.config.network.mode.displayName)
                FactRow(title: "Disk") {
                    HStack {
                        UsageRing(fraction: Double(vm.diskUsed) / Double(max(vm.diskSize, 1)))
                            .accessibilityLabel("Disk usage")
                        Text("\(ByteSize.format(vm.diskUsed)) of \(ByteSize.format(vm.diskSize))")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        } accessory: {
            Button("Edit", action: edit)
        }
    }
}

private struct UsageRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: Metrics.lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Metrics.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Metrics.controlSize / 2, height: Metrics.controlSize / 2)
        .accessibilityElement()
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}
