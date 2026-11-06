import HangarKit
import HangarSupport
import SwiftUI

struct UsageTiles: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        let samples = store.usageHistory[vm.name] ?? []
        let usage = store.usage[vm.name]
        HStack(spacing: Metrics.bezelSpacing) {
            CPUTile(vm: vm, usage: usage, samples: samples)
            MemoryTile(vm: vm, usage: usage, samples: samples)
            DiskTile(usage: usage, samples: samples)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CPUTile: View {
    let vm: VMItem
    let usage: VMUsage?
    let samples: [UsageSample]

    var body: some View {
        UsageTile(
            title: "CPU",
            value: usage?.cpuShare(of: vm.config.cpuCount).map(VMUsage.formatShare) ?? "–",
            samples: samples, maximum: 1,
            series: [UsageSeries(name: "CPU", tint: .blue) { $0.cpu }],
            describe: VMUsage.formatShare
        ) {
            if let cpu = usage?.cpu {
                Text(String(format: "%.1f of %d cores", cpu, vm.config.cpuCount))
            }
        }
    }
}

private struct MemoryTile: View {
    let vm: VMItem
    let usage: VMUsage?
    let samples: [UsageSample]

    var body: some View {
        UsageTile(
            title: "Memory",
            value: usage.map { ByteSize.format($0.memoryInUse) } ?? "–",
            samples: samples, maximum: Double(vm.config.memorySize),
            series: memorySeries(guest: usage?.guestMemory != nil),
            describe: { ByteSize.format(UInt64($0)) },
            detail: {
                HStack(spacing: Metrics.bezelSpacing) {
                    if let guest = usage?.guestMemory {
                        LegendMark(title: "Guest \(ByteSize.format(guest.used))", color: .purple)
                            .help("Used inside the guest, without its file cache")
                    }
                    LegendMark(title: "This Mac \(usage.map { ByteSize.format($0.memory) } ?? "–")", color: .gray)
                        .help("What the VM takes on this Mac")
                }
            }
        )
    }

    private func memorySeries(guest: Bool) -> [UsageSeries] {
        let host = UsageSeries(name: "This Mac", tint: .gray) { Double($0.memory) }
        guard guest else { return [host] }
        return [UsageSeries(name: "Guest", tint: .purple) { Double($0.guestMemory ?? 0) }, host]
    }
}

private struct DiskTile: View {
    /// The chart reaches at least 1 MiB/s, so an idle disk draws a flat line, not noise filling the tile.
    private static let rateFloor = Double(ByteSize.mib)

    let usage: VMUsage?
    let samples: [UsageSample]

    var body: some View {
        UsageTile(
            title: "Disk",
            value: VMUsage.formatRate(diskTotal),
            samples: samples, maximum: Self.rateFloor,
            series: [
                UsageSeries(name: "Read", tint: .teal) { $0.diskRead },
                UsageSeries(name: "Write", tint: .orange) { $0.diskWrite },
            ],
            describe: { VMUsage.formatRate($0) },
            detail: {
                HStack(spacing: Metrics.bezelSpacing) {
                    LegendMark(title: "Read \(VMUsage.formatRate(usage?.diskRead))", color: .teal)
                    LegendMark(title: "Write \(VMUsage.formatRate(usage?.diskWrite))", color: .orange)
                }
            }
        )
    }

    private var diskTotal: Double? {
        guard let usage, usage.diskRead != nil || usage.diskWrite != nil else { return nil }
        return (usage.diskRead ?? 0) + (usage.diskWrite ?? 0)
    }
}
