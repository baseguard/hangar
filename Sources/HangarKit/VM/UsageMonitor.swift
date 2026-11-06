import Darwin
import Foundation
import HangarSupport
import Synchronization

package struct VMUsage: Hashable, Sendable {
    package var cpu: Double?
    package var memory: UInt64
    package var diskRead: Double?
    package var diskWrite: Double?
    package var guestMemory: GuestMemory?
    package var agentVersion: Int?
    package var hasScreen: Bool?

    package var memoryInUse: UInt64 { guestMemory?.used ?? memory }

    package func cpuShare(of cpuCount: Int) -> Double? {
        cpu.map { $0 / Double(max(cpuCount, 1)) }
    }

    package func cpuText(of cpuCount: Int) -> String? {
        cpuShare(of: cpuCount).map { Self.formatShare($0) + " CPU" }
    }

    /// A VM's share is of one core, so a VM with many is often past 100 %; three digits are as far as the fields go.
    private static let largestShownShare = 9.99

    package static func formatShare(_ share: Double) -> String {
        String(format: "%.0f%%", min(max(share, 0), largestShownShare) * 100)
    }

    package static func formatRate(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { ByteSize.format(UInt64(max($0, 0))) + "/s" } ?? "–"
    }
}

package final class UsageMonitor: Sendable {
    private struct Totals {
        var cpuTime: UInt64
        var read: UInt64
        var written: UInt64
        var takenAt: UInt64
    }

    /// A process that turned out not to be a VM is looked at again only after this long.
    private static let otherProcessRecheck: UInt64 = 30 * NSEC_PER_SEC
    /// Room in the pid list for processes that start between the count and the list.
    private static let pidListSlack = 64

    private struct State {
        var names: [pid_t: String] = [:]
        var unmatchedUntil: [pid_t: UInt64] = [:]
        var previous: [pid_t: Totals] = [:]
    }

    private static let processPath = "com.apple.Virtualization.VirtualMachine.xpc"

    private let state = Mutex(State())
    private let ticksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    package init() {}

    package func sample() -> [String: VMUsage] {
        state.withLock { state in
            var usage: [String: VMUsage] = [:]
            var seen: Set<pid_t> = []
            for pid in Self.virtualMachineProcesses() {
                seen.insert(pid)
                guard let (name, current) = measure(pid, state: &state) else { continue }
                usage[name] = current
            }

            state.names = state.names.filter { seen.contains($0.key) }
            state.unmatchedUntil = state.unmatchedUntil.filter { seen.contains($0.key) }
            state.previous = state.previous.filter { seen.contains($0.key) }
            return usage
        }
    }

    private func measure(_ pid: pid_t, state: inout State) -> (name: String, usage: VMUsage)? {
        let now = DispatchTime.now().uptimeNanoseconds
        if state.names[pid] == nil, let until = state.unmatchedUntil[pid], now < until { return nil }
        guard let name = state.names[pid] ?? Self.vmName(of: pid) else {
            state.unmatchedUntil[pid] = state.unmatchedUntil[pid] == nil ? now : now + Self.otherProcessRecheck
            return nil
        }
        state.names[pid] = name
        guard let totals = totals(of: pid) else { return nil }

        var current = VMUsage(memory: totals.memory)
        if let last = state.previous[pid], totals.value.takenAt > last.takenAt {
            let elapsed = Double(totals.value.takenAt - last.takenAt)
            let seconds = elapsed / 1_000_000_000
            current.cpu = Double(totals.value.cpuTime &- last.cpuTime) / elapsed
            current.diskRead = Double(totals.value.read &- last.read) / seconds
            current.diskWrite = Double(totals.value.written &- last.written) / seconds
        }
        state.previous[pid] = totals.value
        return (name, current)
    }

    private func totals(of pid: pid_t) -> (value: Totals, memory: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let cpu = Double(info.ri_user_time + info.ri_system_time) * ticksToNanoseconds
        let totals = Totals(
            cpuTime: UInt64(cpu), read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten,
            takenAt: DispatchTime.now().uptimeNanoseconds)
        return (totals, info.ri_phys_footprint)
    }

    private static func virtualMachineProcesses() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + pidListSlack)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(max(count, 0))).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0
                && String(nulTerminated: path).contains(processPath)
        }
    }

    private static func vmName(of pid: pid_t) -> String? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }

        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }

        let libraries = [HangarPaths.vms.path, HangarPaths.vms.resolvingSymlinksInPath().path]
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let length = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, length) == length else {
                continue
            }

            let path = String(
                nulTerminated: withUnsafeBytes(of: info.pvip.vip_path) { Array($0.bindMemory(to: CChar.self)) })
            let file = URL(fileURLWithPath: path)
            guard file.lastPathComponent == "disk.img",
                libraries.contains(file.deletingLastPathComponent().deletingLastPathComponent().path)
            else { continue }
            return file.deletingLastPathComponent().lastPathComponent
        }

        return nil
    }
}
