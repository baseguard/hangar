import Darwin
import Foundation
import HangarPackets
import HangarSupport
import vmnet

package enum SharedNetwork {
    /// The daemon's first start downloads nothing, but vmnet can hold a subnet for minutes after a stop.
    package static let daemonStartTimeout: TimeInterval = 200
    private static let daemonStopTimeout: TimeInterval = 5
    private static let usersLockWait: TimeInterval = 1
    private static let shownLogLines = 15

    static var directory: URL { HangarPaths.network }
    static var daemonLockURL: URL { directory.appendingPathComponent("netd.lock") }
    static var usersLockURL: URL { directory.appendingPathComponent("users.lock") }
    static var serializationURL: URL { directory.appendingPathComponent("network.bin") }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    package static var logURL: URL { directory.appendingPathComponent("netd.log") }

    static let serializationKey = "networkSerialization"

    package struct Settings: Codable, Sendable {
        package var subnet: IPv4Subnet
    }

    package struct State: Codable, Equatable, Sendable {
        package var pid: pid_t
        package var subnet: IPv4Subnet
        package var startedAt: Date
        package var build: BuildStamp?
        package var gatewayMAC: String
        package var serverMAC: String
    }

    package static var subnet: IPv4Subnet {
        (try? JSON.read(Settings.self, from: settingsURL))?.subnet ?? .default
    }

    package static func setSubnet(_ subnet: IPv4Subnet) throws {
        try HangarPaths.createDirectory(directory)
        try JSON.write(Settings(subnet: subnet), to: settingsURL)
    }

    package static var isDaemonRunning: Bool {
        FileLock.isHeld(daemonLockURL)
    }

    package static var state: State? {
        guard isDaemonRunning, let state = try? JSON.read(State.self, from: stateURL),
            (daemonPID ?? state.pid) == state.pid, ProcessUtil.isAlive(state.pid)
        else { return nil }
        return state
    }

    /// The daemon holding the lock, also while it is still starting and hasn't published its network.
    package static var daemonHoldingLock: pid_t? {
        guard isDaemonRunning, let pid = daemonPID, ProcessUtil.isAlive(pid) else { return nil }
        return pid
    }

    static var daemonPID: pid_t? {
        (try? String(contentsOf: daemonLockURL, encoding: .utf8)).flatMap {
            pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    package static func ensureDaemon(timeout: TimeInterval = SharedNetwork.daemonStartTimeout) throws -> State {
        if let state {
            if let build = state.build, let current = BuildStamp.current, build != current {
                throw HangarError(
                    "Hangar's network is run by a Hangar signed differently (\(build.signer), pid \(state.pid); this one: \(current.signer)), so a VM started from this one would get no network. Shut down the VMs on it (hangar stop --all), run `hangar network stop`, then start the VM again."
                )
            }
            return state
        }

        try HangarPaths.createDirectory(directory)
        let pid = try ProcessUtil.spawnDetached(HangarExecutable.url, arguments: ["_netd"], logURL: logURL)
        var current: State?
        let ready = ProcessUtil.wait(timeout: timeout) {
            current = state
            return current != nil || (ProcessUtil.hasExited(pid) && !isDaemonRunning)
        }
        guard ready, let current else {
            if let pid = daemonHoldingLock {
                throw HangarError(
                    "Hangar's network daemon (pid \(pid)) runs but hasn't set up its network. See \(logURL.path), or run `hangar network stop` and start the VM again."
                )
            }
            let lastLines = LogFile.lastLines(shownLogLines, of: logURL).joined(separator: "\n")
            throw HangarError("The network daemon failed to start:\n\(lastLines)")
        }

        return current
    }

    @discardableResult
    package static func stopDaemon() -> Bool {
        guard let pid = state?.pid ?? daemonHoldingLock else { return !isDaemonRunning }
        kill(pid, SIGTERM)
        return ProcessUtil.wait(timeout: daemonStopTimeout) { !isDaemonRunning }
    }

    static func readLeases() throws -> [String: DHCPServer.Lease] {
        guard FileManager.default.fileExists(atPath: DHCPService.leasesURL.path) else { return [:] }
        return try JSON.read([String: DHCPServer.Lease].self, from: DHCPService.leasesURL)
    }

    static func leasedAddresses() -> [String: IPv4Address] {
        ((try? readLeases()) ?? [:]).mapValues(\.ip)
    }

    @discardableResult
    package static func changeSubnet(to subnet: IPv4Subnet) throws -> [String] {
        try HostInterfaces.checkNoClash(with: subnet)
        try HangarPaths.createDirectory(directory)
        let usersLock = FileLock(url: usersLockURL)
        guard try usersLock.tryLock(.exclusive, retryingFor: usersLockWait) else {
            throw HangarError("Shut down the Hangar Managed VMs first.")
        }
        defer { usersLock.unlock() }
        guard stopDaemon() else {
            throw HangarError("Hangar's network did not stop. See \(logURL.path).")
        }

        try setSubnet(subnet)
        try? FileManager.default.removeItem(at: DHCPService.leasesURL)

        let bundles = VMLibrary.all()
        let kept = addressesKept(by: bundles, in: subnet)
        let free = subnet.reservableRange.filter {
            !subnet.unavailableAddresses.contains($0) && !kept.addresses.contains($0)
        }
        return reassignAddresses(of: bundles.filter { !kept.vmNames.contains($0.name) }, from: free)
    }

    /// The VMs whose address already lies in the new subnet keep it; the first VM to claim an address wins it.
    private static func addressesKept(
        by bundles: [VMBundle], in subnet: IPv4Subnet
    ) -> (addresses: Set<UInt32>, vmNames: Set<String>) {
        var addresses = Set<UInt32>()
        var vmNames = Set<String>()
        for bundle in bundles {
            guard let ip = (try? bundle.loadConfig())?.network.ipAddress.flatMap(IPv4Address.init), subnet.contains(ip),
                !subnet.unavailableAddresses.contains(ip.value), addresses.insert(ip.value).inserted
            else { continue }
            vmNames.insert(bundle.name)
        }
        return (addresses, vmNames)
    }

    /// Gives each managed VM the next free address; the names of the VMs whose config couldn't be changed.
    private static func reassignAddresses(of bundles: [VMBundle], from free: [UInt32]) -> [String] {
        var free = free.makeIterator()
        var skipped: [String] = []
        for bundle in bundles {
            do {
                try bundle.updateConfig { config in
                    guard config.network.mode == .managed || config.network.ipAddress != nil else { return }
                    config.network.ipAddress = free.next().map { IPv4Address($0).description }
                }
            } catch {
                skipped.append(bundle.name)
            }
        }
        return skipped
    }

    static func reservations(in subnet: IPv4Subnet) -> [String: IPv4Address] {
        var result: [String: IPv4Address] = [:]
        for bundle in VMLibrary.all() {
            guard let config = try? bundle.loadConfig(), config.network.mode == .managed,
                let mac = MACAddress.normalize(config.network.macAddress),
                let ip = config.network.ipAddress.flatMap(IPv4Address.init),
                subnet.contains(ip), !subnet.unavailableAddresses.contains(ip.value), !result.values.contains(ip)
            else { continue }
            result[mac] = ip
        }
        return result
    }
}

func releaseVMNet(_ object: OpaquePointer) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(object)).release()
}
