import HangarKit
import HangarSupport

nonisolated struct VMItem: Identifiable, Hashable, Sendable {
    var bundle: VMBundle
    var config: VMConfig
    var run: RunInfo?
    var state: MachineState
    var ip: String?
    var diskSize: UInt64
    var diskUsed: UInt64
    var snapshots: [VMSnapshot]

    var id: String { bundle.name }
    var name: String { bundle.name }
    var isRunning: Bool { run != nil }
}

extension VMItem {
    var phase: VMPhase { VMPhase(state) }

    var canChangeISO: Bool { run?.liveISO ?? true }

    var summary: String {
        let memory = ByteSize.format(config.memorySize)
        return "\(config.os.displayName) · \(config.cpuCount) CPU\(config.cpuCount == 1 ? "" : "s") · \(memory)"
    }
}
