import Darwin
import Foundation
import HangarPackets
import HangarSecrets
import HangarSupport
import Observation
import Virtualization

/// Building the virtual machine: the run lock, the managed network's lease and guard and Virtualization's
/// configuration, all before the session exists.
extension VMSession {
    /// The lease and traffic guard of the managed network, set up before the session so the app can wait for vmnet,
    /// which can take seconds to answer when it is in trouble, off the main actor.
    package struct ManagedNetwork {
        let lease: SharedNetworkLease
        let trafficGuard: TrafficGuard
    }

    nonisolated package static func setUpManagedNetwork(for bundle: VMBundle) throws -> ManagedNetwork {
        let lease = try SharedNetworkLease.acquire()
        var config = try bundle.loadConfig()
        try reserveAddress(in: lease, for: bundle, config: &config)
        let trafficGuard = try TrafficGuard(
            bundle: bundle, config: config, serialization: lease.serialization, network: lease.state)
        return ManagedNetwork(lease: lease, trafficGuard: trafficGuard)
    }

    struct StartDevices {
        var playsAudio: Bool
        var usbPassthrough: Bool
    }

    struct Machine {
        let lease: SharedNetworkLease?
        let trafficGuard: TrafficGuard?
        let virtualMachine: VZVirtualMachine
    }

    static func checkRunOnlyFolders(_ folders: [SharedFolder], for bundle: VMBundle, config: VMConfig) throws {
        for folder in folders {
            guard !SharedFolder.isReserved(folder.name) else {
                throw HangarError(
                    "Hangar uses the name '\(folder.name)' for its own folder; give this folder another name (name:path)."
                )
            }
            guard !config.sharedFolders.contains(where: { $0.name == folder.name }),
                folders.count(where: { $0.name == folder.name }) == 1
            else {
                throw HangarError(
                    "'\(bundle.name)' already shares a folder named '\(folder.name)'; give this one another name (name:path)."
                )
            }
        }
    }

    static func takeRunLock(of bundle: VMBundle, host: RunInfo.Host) throws -> FileLock {
        let lock = FileLock(url: bundle.lockURL)
        guard try lock.tryLock(.exclusive, retryingFor: 0.5) else { throw alreadyRunning(bundle.name) }
        try lock.write(JSON.encoder.encode(RunInfo(pid: getpid(), host: host)))
        return lock
    }

    package static func alreadyRunning(_ name: String) -> HangarError {
        HangarError("'\(name)' is already running.")
    }

    static func makeMachine(
        bundle: VMBundle, config: inout VMConfig, host: RunInfo.Host, lock: FileLock, console: ConsoleMode,
        bootISO: URL?, devices: StartDevices, agentInput: Pipe, agentOutput: Pipe, managedNetwork: ManagedNetwork?
    ) throws -> Machine {
        var trafficGuard = managedNetwork?.trafficGuard
        do {
            try VMLibrary.checkNotTwin(bundle, config: config)
            try config.traffic.checkRunnable(on: config.network.mode)
            let lease = try joinManagedNetwork(
                bundle: bundle, config: &config, managedNetwork: managedNetwork, trafficGuard: &trafficGuard)

            let configuration = try ConfigurationBuilder(
                bundle: bundle, config: config, console: console,
                bootISO: bootISO, playsAudio: devices.playsAudio,
                agentInput: agentInput.fileHandleForReading, agentOutput: agentOutput.fileHandleForWriting,
                usbPassthrough: devices.usbPassthrough, guestNetwork: trafficGuard?.guestHandle
            ).build()
            let virtualMachine = VZVirtualMachine(configuration: configuration)
            try recordLiveDevices(of: virtualMachine, config: config, host: host, bootISO: bootISO, in: lock)
            return Machine(lease: lease, trafficGuard: trafficGuard, virtualMachine: virtualMachine)
        } catch {
            trafficGuard?.stop()
            throw error
        }
    }

    /// The VM's lease on Hangar's network, with the traffic guard that watches it; nothing on NAT or no network.
    private static func joinManagedNetwork(
        bundle: VMBundle, config: inout VMConfig, managedNetwork: ManagedNetwork?, trafficGuard: inout TrafficGuard?
    ) throws -> SharedNetworkLease? {
        guard config.network.mode == .managed else {
            // The VM left the managed network after it was set up.
            trafficGuard?.stop()
            trafficGuard = nil
            return nil
        }

        let lease = try managedNetwork?.lease ?? SharedNetworkLease.acquire()
        try reserveAddress(in: lease, for: bundle, config: &config)
        if trafficGuard == nil {
            trafficGuard = try TrafficGuard(
                bundle: bundle, config: config, serialization: lease.serialization, network: lease.state)
        }
        return lease
    }

    nonisolated static func reserveAddress(
        in lease: SharedNetworkLease, for bundle: VMBundle, config: inout VMConfig
    ) throws {
        let address = config.network.ipAddress.flatMap(IPv4Address.init)
        guard address.map(lease.state.subnet.contains) != true else { return }
        let stored = try bundle.updateConfig { $0.network.ipAddress = VMLibrary.allocateIPAddress() }
        config.network.ipAddress = stored.network.ipAddress
    }

    private static func recordLiveDevices(
        of virtualMachine: VZVirtualMachine, config: VMConfig, host: RunInfo.Host, bootISO: URL?, in lock: FileLock
    ) throws {
        let liveISO = !virtualMachine.usbControllers.isEmpty && bootISO == nil && config.isoPath == nil
        let info = RunInfo(pid: getpid(), host: host, liveISO: liveISO)
        try lock.write(JSON.encoder.encode(info))
    }
}
