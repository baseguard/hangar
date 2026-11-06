import Darwin
import Foundation
import HangarPackets
import HangarSupport
import OSLog
import vmnet

package enum NetworkDaemon {
    /// vmnet frees a stopped network's subnet within a few minutes; after a crash there is nothing to wait for.
    private static let vmnetReleaseAttempts = 90
    private static let vmnetReleaseAttemptsAfterCrash = 10
    private static let vmnetReleaseInterval: UInt32 = 2
    private static let daemonLockWait: TimeInterval = 0.5

    private static let idleChecksBeforeExit = 120
    private static let checkInterval: TimeInterval = 5
    package static let idleMinutes = idleChecksBeforeExit * Int(checkInterval) / 60

    package static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let daemonLock = takeDaemonLock()
        let signals = holdSignals()
        let crashed = clearPreviousState()
        let subnet = SharedNetwork.subnet
        let service = startNetwork(subnet: subnet, crashed: crashed)
        publishState(subnet: subnet, service: service)
        shutDown(on: signals, service: service)
        let timer = startIdleTimer(service: service)
        withExtendedLifetime((daemonLock, service, signals, timer)) {
            dispatchMain()
        }
    }

    private static func takeDaemonLock() -> FileLock {
        let lock = FileLock(url: SharedNetwork.daemonLockURL)
        guard (try? lock.tryLock(.exclusive, retryingFor: daemonLockWait)) == true else {
            log("another network daemon is already running")
            exit(0)
        }
        // The pid only lets `hangar network status` name a starting daemon; without it the daemon still runs.
        do {
            try lock.write(Data("\(getpid())\n".utf8))
        } catch {
            log("could not record this daemon's pid: \(error.localizedDescription)")
        }
        return lock
    }

    private static func clearPreviousState() -> SharedNetwork.State? {
        let previous = try? JSON.read(SharedNetwork.State.self, from: SharedNetwork.stateURL)
        removePublishedFiles()
        if FileManager.default.fileExists(atPath: SharedNetwork.settingsURL.path),
            (try? JSON.read(SharedNetwork.Settings.self, from: SharedNetwork.settingsURL)) == nil
        {
            log("warning: \(SharedNetwork.settingsURL.path) is not valid; using \(IPv4Subnet.default)")
        }
        return previous
    }

    private static func removePublishedFiles() {
        try? FileManager.default.removeItem(at: SharedNetwork.stateURL)
        try? FileManager.default.removeItem(at: SharedNetwork.serializationURL)
    }

    private static func startNetwork(subnet: IPv4Subnet, crashed: SharedNetwork.State?) -> DHCPService {
        do {
            try HostInterfaces.checkNoClash(with: subnet)
            let attempts = crashed == nil ? vmnetReleaseAttempts : vmnetReleaseAttemptsAfterCrash
            let network = try createNetworkWaiting(subnet: subnet, attempts: attempts)
            do {
                try writeSerialization(of: network)
            } catch {
                releaseVMNet(network)
                throw error
            }
            return try DHCPService(subnet: subnet, network: network, log: log)
        } catch {
            if error is SubnetBusy, let crashed {
                log(
                    "error: the previous network daemon (pid \(crashed.pid)) stopped unexpectedly, and the VMs that were using its network keep \(subnet) busy. Shut them down (hangar stop --all), then start them again."
                )
            } else if error is SubnetBusy {
                log(
                    "error: macOS is still holding \(subnet) for an earlier Hangar network, or another user on this Mac runs Hangar on it. It is freed once no other virtual machine on this Mac uses macOS's shared networking, or after a restart. To go on now, move Hangar to another subnet with all VMs stopped: hangar network set --subnet 192.168.73.1/24"
                )
            } else {
                log("error: \(error.localizedDescription)")
            }
            exit(1)
        }
    }

    private static func publishState(subnet: IPv4Subnet, service: DHCPService) {
        guard let gatewayMAC = service.gatewayMAC() else {
            log("error: could not find the MAC address of the gateway \(subnet.gateway)")
            service.close()
            exit(1)
        }

        let serverMAC = MACAddress.string(service.mac)

        do {
            try JSON.write(
                SharedNetwork.State(
                    pid: getpid(), subnet: subnet, startedAt: Date(), build: BuildStamp.current,
                    gatewayMAC: MACAddress.string(gatewayMAC), serverMAC: serverMAC),
                to: SharedNetwork.stateURL)
        } catch {
            log("error: could not publish the network: \(error.localizedDescription)")
            service.close()
            exit(1)
        }

        log(
            "network \(subnet) ready with \(SharedNetwork.reservations(in: subnet).count) reservation(s), gateway \(MACAddress.string(gatewayMAC)), DHCP server \(serverMAC)"
        )
    }

    private static func shutDown(_ reason: String, service: DHCPService) -> Never {
        log("shutting down: \(reason)")
        removePublishedFiles()
        service.close()
        exit(0)
    }

    /// vmnet can take minutes to give the network out, and a daemon killed meanwhile keeps the subnet busy.
    /// So signals don't end the process; the sources hold them, and the main queue, which runs only once the
    /// network is up, hands them to the handler `shutDown(on:service:)` sets.
    private static func holdSignals() -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.resume()
            return source
        }
    }

    private static func shutDown(on signals: [DispatchSourceSignal], service: DHCPService) {
        for source in signals {
            let number = source.handle
            source.setEventHandler { shutDown("signal \(number)", service: service) }
        }
    }

    private static func startIdleTimer(service: DHCPService) -> DispatchSourceTimer {
        let usersLock = FileLock(url: SharedNetwork.usersLockURL)
        var idleChecks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler {
            service.maintain()
            guard (try? usersLock.tryLock(.exclusive)) == true else {
                idleChecks = 0
                return
            }
            idleChecks += 1
            if idleChecks >= idleChecksBeforeExit {
                shutDown("no VMs attached", service: service)
            }
            usersLock.unlock()
        }
        timer.resume()

        return timer
    }

    private static func createNetworkWaiting(subnet: IPv4Subnet, attempts: Int) throws -> vmnet_network_ref {
        var attempt = 0
        while true {
            do {
                return try createNetwork(subnet: subnet)
            } catch let error as SubnetBusy where attempt < attempts {
                attempt += 1
                if attempt == 1 { log("waiting for vmnet to release \(subnet) (\(error.status))…") }
                sleep(vmnetReleaseInterval)
            }
        }
    }

    private static func createNetwork(subnet: IPv4Subnet) throws -> vmnet_network_ref {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw HangarError("vmnet_network_configuration_create failed (\(status.rawValue))")
        }
        defer { releaseVMNet(configuration) }
        var gateway = subnet.gateway.inAddr
        var mask = subnet.mask.inAddr
        status = vmnet_network_configuration_set_ipv4_subnet(configuration, &gateway, &mask)
        guard status == .VMNET_SUCCESS else {
            throw HangarError("invalid subnet \(subnet) (\(status.rawValue))")
        }

        vmnet_network_configuration_disable_dhcp(configuration)
        guard let network = vmnet_network_create(configuration, &status) else {
            switch status {
            case .VMNET_FAILURE:
                throw SubnetBusy(status: status.rawValue)
            case .VMNET_MEM_FAILURE:
                throw HangarError(
                    "vmnet refused to create the network (status \(status.rawValue)); this build may lack the virtualization entitlement"
                )
            default:
                throw HangarError("vmnet refused to create the network (status \(status.rawValue))")
            }
        }

        return network
    }

    private struct SubnetBusy: LocalizedError {
        let status: UInt32
        var errorDescription: String? { "vmnet_network_create failed (\(status))" }
    }

    private static func writeSerialization(of network: vmnet_network_ref) throws {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let serialization = vmnet_network_copy_serialization(network, &status),
            let value = xpc_dictionary_get_value(serialization, SharedNetwork.serializationKey),
            let bytes = xpc_data_get_bytes_ptr(value)
        else {
            throw HangarError("vmnet_network_copy_serialization failed (\(status.rawValue))")
        }

        let data = Data(bytes: bytes, count: xpc_data_get_length(value))
        try data.write(to: SharedNetwork.serializationURL, options: .atomic)
    }

    private static let logger = HangarLog.logger("network")

    private static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let stamp = Date.now.formatted(.iso8601)
        print("[\(stamp)] netd[\(getpid())]: \(message)")
    }
}
