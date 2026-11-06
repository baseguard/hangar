import Darwin
import Foundation
import HangarPackets
import HangarSecrets
import HangarSupport
import HangarTraffic
import Synchronization
import vmnet

package actor TrafficGuard {
    /// The guest's frames come through a socket pair: a frame's buffer, and room for a burst on each side.
    private static let frameBuffer = 65_536
    private static let sendBuffer: Int32 = 1 << 20
    private static let receiveBuffer: Int32 = 4 << 20
    /// Flows expire on every tick; the host's addresses and the loss count are looked at less often.
    private static let tickInterval: DispatchTimeInterval = .seconds(5)
    private static let hostAddressRefreshTicks = 6
    private static let lossReportTicks = 12

    nonisolated let guestHandle: FileHandle
    private let socket: Int32
    private let queue = DispatchSerialQueue(label: "io.baseguard.hangar.traffic", qos: .userInitiated)
    private let inspector: TrafficInspector
    private let writer: TrafficLog.Writer
    private let network: vmnet_network_ref
    private var port: VMNetInterface?
    private var source: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var ticks = 0
    private var hasFinished = false
    private var lostToGuest = 0
    private let name: String
    private var buffer = [UInt8](repeating: 0, count: TrafficGuard.frameBuffer)
    /// The host's address in the VM network, where the secrets proxy listens.
    private let gateway: IPv4Address
    private let divertedConnections = DivertedConnections()
    private var secretsProxy: SecretsProxyServer?

    package nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(bundle: VMBundle, config: VMConfig, serialization: Data, network state: SharedNetwork.State) throws {
        let macs = try Self.macAddresses(guest: config.network.macAddress, network: state)
        let sockets = try Self.makeSocketPair()
        guestHandle = FileHandle(fileDescriptor: sockets.guest, closeOnDealloc: true)
        socket = sockets.host
        inspector = TrafficInspector(
            guestMAC: macs.guest, guestIP: config.network.ipAddress.flatMap(IPv4Address.init)?.value,
            subnet: state.subnet, gatewayMAC: macs.gateway, serverMAC: macs.server, policy: config.traffic)
        writer = TrafficLog.Writer(url: bundle.trafficLogURL)
        name = bundle.name
        gateway = state.subnet.gateway

        let relay = FrameRelay()
        do {
            network = try SharedNetworkLease.join(serialization)
            port = try VMNetInterface(network: network, queue: queue, macAddress: macs.guest) { relay.deliver($0) }
        } catch {
            close(sockets.host)
            writer.close()
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: sockets.host, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.source = source
        self.timer = timer
        startHandlingEvents(from: relay, guest: source, timer: timer)
    }

    private static func macAddresses(
        guest: String, network state: SharedNetwork.State
    ) throws -> (guest: [UInt8], gateway: [UInt8], server: [UInt8]) {
        guard let guestMAC = MACAddress.bytes(guest) else {
            throw HangarError("Invalid MAC address '\(guest)'.")
        }
        guard let gatewayMAC = MACAddress.bytes(state.gatewayMAC), let serverMAC = MACAddress.bytes(state.serverMAC)
        else {
            throw HangarError(
                "Hangar's network didn't publish its gateway and DHCP server addresses. Run `hangar network stop` and start the VM again."
            )
        }
        return (guestMAC, gatewayMAC, serverMAC)
    }

    private static func makeSocketPair() throws -> (guest: Int32, host: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw HangarError(errno: errno, "Could not make the socket pair for the guest's traffic")
        }

        for fd in fds {
            var sendSize = sendBuffer
            var receiveSize = receiveBuffer
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveSize, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)

        return (fds[0], fds[1])
    }

    private nonisolated func startHandlingEvents(
        from relay: FrameRelay, guest source: any DispatchSourceRead, timer: any DispatchSourceTimer
    ) {
        relay.connect { [weak self] frame in
            self?.assumeIsolated { trafficGuard in trafficGuard.fromNetwork(frame) }
        }

        let socket = self.socket
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { trafficGuard in trafficGuard.drainGuest() }
        }
        source.setCancelHandler { close(socket) }
        source.activate()

        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { trafficGuard in trafficGuard.tick() }
        }
        timer.activate()

        queue.async { [weak self] in
            self?.assumeIsolated { trafficGuard in trafficGuard.begin() }
        }
    }

    isolated deinit {
        releaseVMNet(network)
    }

    static func hostAddresses() -> Set<UInt32> {
        Set(HostInterfaces.addresses().map(\.address.value))
    }

    nonisolated func update(_ policy: TrafficPolicy) {
        queue.async { [weak self] in
            self?.assumeIsolated { trafficGuard in
                trafficGuard.apply(trafficGuard.inspector.update(policy, now: Date()))
            }
        }
    }

    /// Starts, changes or stops the secrets proxy, and tells the inspector which hosts go to it.
    nonisolated func useSecrets(_ secrets: SecretsProxyServer.Secrets?) {
        queue.async { [weak self] in
            self?.assumeIsolated { trafficGuard in trafficGuard.applySecrets(secrets) }
        }
    }

    private func applySecrets(_ secrets: SecretsProxyServer.Secrets?) {
        guard !hasFinished, let secrets else {
            stopSecretsProxy()
            return
        }
        do {
            let proxy = try secretsProxy ?? startSecretsProxy(with: secrets)
            proxy.update(secrets)
            inspector.useSecrets(
                for: secrets.hosts,
                proxy: SecretsDiversion(endpoint: proxy.endpoint, connections: divertedConnections))
        } catch {
            HangarLog.warning("'\(name)' can't put its secrets in: the secrets proxy didn't start (\(error)).")
            stopSecretsProxy()
        }
    }

    private func startSecretsProxy(with secrets: SecretsProxyServer.Secrets) throws -> SecretsProxyServer {
        let proxy = try SecretsProxyServer.start(
            on: gateway, connections: divertedConnections, secrets: secrets
        ) { [weak self] event in
            self?.queue.async { [weak self] in self?.assumeIsolated { $0.writer.write(event) } }
        }
        secretsProxy = proxy
        return proxy
    }

    private func stopSecretsProxy() {
        secretsProxy?.stop()
        secretsProxy = nil
        inspector.useSecrets(for: [], proxy: nil)
    }

    nonisolated func stop() {
        queue.sync {
            assumeIsolated { trafficGuard in trafficGuard.finish() }
        }
    }

    private func begin() {
        inspector.hostAddresses = Self.hostAddresses()
        apply(inspector.start(now: Date()))
    }

    private func tick() {
        ticks += 1
        if ticks % Self.hostAddressRefreshTicks == 0 { inspector.hostAddresses = Self.hostAddresses() }
        if ticks % Self.lossReportTicks == 0 { reportLosses() }
        apply(inspector.expire(now: Date()))
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        stopSecretsProxy()
        timer?.cancel()
        port?.stop()
        port = nil
        source?.cancel()
        for event in inspector.finish(now: Date()).events {
            writer.write(event)
        }
        writer.close()
    }

    /// Once a minute at most, so a guest that can't keep up doesn't flood the log.
    private func reportLosses() {
        let lostEntries = writer.takeFailedWrites()
        guard lostToGuest > 0 || lostEntries > 0 else { return }
        HangarLog.warning(
            "'\(name)' lost \(lostToGuest) frames on the way to the guest and \(lostEntries) traffic log entries in the last minute."
        )
        lostToGuest = 0
    }

    private func drainGuest() {
        while !hasFinished {
            let count = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }
            apply(inspector.fromGuest(Array(buffer[0..<count]), now: Date()))
        }
    }

    private func fromNetwork(_ frame: [UInt8]) {
        apply(inspector.fromNetwork(frame, now: Date()))
    }

    private func apply(_ output: TrafficInspector.Output) {
        guard !hasFinished else { return }
        for frame in output.toGuest {
            let sent = frame.withUnsafeBytes { send(socket, $0.baseAddress, $0.count, 0) }
            if sent < 0 { lostToGuest += 1 }
        }
        for frame in output.toNetwork {
            port?.send(frame)
        }
        for event in output.events {
            writer.write(event)
        }
    }
}
