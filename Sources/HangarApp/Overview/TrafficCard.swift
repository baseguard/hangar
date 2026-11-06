import Charts
import Foundation
import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct TrafficCard: View {
    let vm: VMItem
    let activity: TrafficActivity
    let open: () -> Void

    var body: some View {
        Card(title: "Traffic", systemImage: "arrow.up.arrow.down") {
            if watched {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    TrafficFigure(
                        value: ByteSize.format(activity.received), label: "received", systemImage: "arrow.down")
                    TrafficFigure(value: ByteSize.format(activity.sent), label: "sent", systemImage: "arrow.up")
                    TrafficFigure(
                        value: "\(activity.blocked)", label: "blocked", systemImage: "xmark.octagon",
                        tint: activity.blocked > 0 ? .red : .primary)
                }
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    TrafficTimeline(buckets: activity.timeline, end: activity.latest ?? Date())
                        .frame(height: Metrics.chartHeight)
                    HStack(spacing: Metrics.bezelSpacing) {
                        Text("Connections · last \(TrafficActivity.timelineMinutes) min")
                        Spacer()
                        LegendMark(title: "Allowed", color: .accentColor)
                        LegendMark(title: "Blocked", color: .red)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                Notice(
                    text: vm.config.network.mode == .managed
                        ? "Watching is off for this VM."
                        : "Only Hangar Managed VMs are watched.")
            }
        } accessory: {
            HStack(spacing: Metrics.bezelSpacing) {
                TrafficModeBadge(policy: vm.config.traffic, network: vm.config.network.mode)
                Button("Show All", action: open)
            }
        }
    }

    private var watched: Bool { vm.config.network.mode == .managed && vm.config.traffic.watches }
}

private struct TrafficFigure: View {
    let value: String
    let label: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .contentTransition(.numericText())
            Label(label, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TrafficTimeline: View {
    let buckets: [TrafficActivity.Bucket]
    let end: Date
    private let minutes = TrafficActivity.timelineMinutes

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Time", bucket.start, unit: .minute), y: .value("Connections", bucket.count))
                .foregroundStyle(by: .value("Kind", bucket.kind))
        }
        .chartForegroundStyleScale(["Allowed": Color.accentColor, "Blocked": Color.red])
        .chartLegend(.hidden)
        .chartXScale(domain: end.addingTimeInterval(-Double(minutes * 60))...end)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay {
            if buckets.isEmpty {
                Text("No connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Connections per minute over the last \(minutes) minutes")
    }
}
