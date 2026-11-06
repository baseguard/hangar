import Charts
import Foundation
import SwiftUI

struct UsageSeries {
    let name: String
    let tint: Color
    let metric: (UsageSample) -> Double
}

struct UsageTile<Detail: View>: View {
    let title: String
    let value: String
    let samples: [UsageSample]
    let maximum: Double
    let series: [UsageSeries]
    let describe: (Double) -> String
    @ContentBuilder let detail: Detail

    @State private var selection: Date?

    var body: some View {
        Card {
            UsageHeader(title: title, value: value)
            UsageChart(
                title: title, value: value, samples: samples, maximum: maximum, series: series, describe: describe,
                selection: $selection
            )
            .frame(height: Metrics.chartHeight)
            detail.font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct UsageHeader: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

private struct UsageChart: View {
    let title: String
    let value: String
    let samples: [UsageSample]
    let maximum: Double
    let series: [UsageSeries]
    let describe: (Double) -> String
    @Binding var selection: Date?

    var body: some View {
        let now = samples.last?.date ?? Date()
        let selected = selection.flatMap { date in
            samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }

        let peak = series.flatMap { line in samples.map(line.metric) }.max() ?? 0
        Chart {
            UsageLines(title: title, samples: samples, series: series)
            if let selected, let top = series.max(by: { $0.metric(selected) < $1.metric(selected) }) {
                SelectedSampleMarks(
                    title: title, sample: selected, series: series, top: top, label: label(for: selected))
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-VMStore.usageWindow)...now)
        .chartYScale(domain: 0...max(maximum, peak, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXSelection(value: $selection)
        .accessibilityLabel("\(title) over the last \(Int(VMStore.usageWindow / 60)) minutes")
        .accessibilityValue(value)
    }

    private func label(for sample: UsageSample) -> String {
        guard series.count > 1 else { return series.map { describe($0.metric(sample)) }.joined() }
        return series.map { "\($0.name) \(describe($0.metric(sample)))" }.joined(separator: " · ")
    }
}

private struct UsageLines: ChartContent {
    let title: String
    let samples: [UsageSample]
    let series: [UsageSeries]

    var body: some ChartContent {
        ForEach(series, id: \.name) { line in
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date), y: .value(title, line.metric(sample)),
                    series: .value("Series", line.name), stacking: .unstacked
                )
                .foregroundStyle(line.tint.opacity(Metrics.chartArea))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.date), y: .value(title, line.metric(sample)),
                    series: .value("Series", line.name)
                )
                .foregroundStyle(line.tint)
                .lineStyle(StrokeStyle(lineWidth: Metrics.lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
    }
}

private struct SelectedSampleMarks: ChartContent {
    let title: String
    let sample: UsageSample
    let series: [UsageSeries]
    let top: UsageSeries
    let label: String

    var body: some ChartContent {
        RuleMark(x: .value("Time", sample.date))
            .foregroundStyle(Color.secondary.opacity(Metrics.chartRule))
        ForEach(series, id: \.name) { line in
            PointMark(x: .value("Time", sample.date), y: .value(title, line.metric(sample)))
                .foregroundStyle(line.tint)
        }
        PointMark(x: .value("Time", sample.date), y: .value(title, top.metric(sample)))
            .foregroundStyle(top.tint)
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text("\(label) · \(sample.date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .padding(.horizontal, Metrics.smallControlInset)
                    .frame(height: Metrics.smallControlSize)
                    .background(.regularMaterial, in: .capsule)
            }
    }
}
