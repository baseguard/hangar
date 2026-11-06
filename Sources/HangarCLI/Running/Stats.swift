import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how much processor, memory and disk the running VMs use on this Mac.")

    func run() throws {
        let running = VMLibrary.all().filter(\.isRunning)
        guard !running.isEmpty else {
            print("No VM is running.")
            return
        }

        let monitor = UsageMonitor()
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 1)
        let usage = monitor.sample()
        var rows = [["NAME", "CPU", "MEMORY", "DISK READ", "DISK WRITE"]]

        for bundle in running {
            guard let config = try? bundle.loadConfig(), let current = usage[bundle.name] else {
                rows.append([bundle.name, "–", "–", "–", "–"])
                continue
            }

            let cpu =
                current.cpuShare(of: config.cpuCount).map { String(format: "%.0f%% of %d", $0 * 100, config.cpuCount) }
                ?? "–"
            rows.append([
                bundle.name, cpu, "\(ByteSize.format(current.memory)) of \(ByteSize.format(config.memorySize))",
                VMUsage.formatRate(current.diskRead), VMUsage.formatRate(current.diskWrite),
            ])
        }

        printTable(rows)
    }
}
