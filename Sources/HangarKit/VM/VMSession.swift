import Darwin
import Foundation
import HangarPackets
import HangarSecrets
import HangarSupport
import Observation
import Virtualization

@MainActor
@Observable
package final class VMSession: NSObject {
    package let bundle: VMBundle
    package private(set) var config: VMConfig
    package private(set) var state: VZVirtualMachine.State = .stopped
    package private(set) var stopError: Error?
    package private(set) var networkError: String?

    @ObservationIgnored package let virtualMachine: VZVirtualMachine
    @ObservationIgnored package var didStop: ((Error?) -> Void)?
    /// Told when the setup commands end, with why one failed.
    @ObservationIgnored package var setupEnded: ((Error?) -> Void)?
    /// The setup command running now, for the window to show.
    package private(set) var setupStatus: String?
    @ObservationIgnored private var isRunningSetup = false

    @ObservationIgnored private let agentInput: Pipe
    @ObservationIgnored private let agentOutput: Pipe
    @ObservationIgnored private let agentReports = GuestReports()
    @ObservationIgnored private let runLock: FileLock
    @ObservationIgnored private var networkLease: SharedNetworkLease?
    @ObservationIgnored private var trafficGuard: TrafficGuard?
    /// What the guest agent is told to trust and set (`TrustCommand`), sent each time the agent shows up.
    @ObservationIgnored private var trustLine = TrustCommand.line(authority: nil, rules: [])
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var stateObservation: NSKeyValueObservation?
    @ObservationIgnored private let startUpFromRecovery: Bool
    @ObservationIgnored private let runOnlyFolders: [SharedFolder]
    @ObservationIgnored private var hasFinished = false
    @ObservationIgnored private var isRepeatingStopRequest = false
    @ObservationIgnored private var isTakingSnapshot = false

    /// How a stop waits: polling the machine's state, asking a booting guest again, and giving up on a shutdown.
    private static let pollInterval = Duration.milliseconds(200)
    private static let stopRetries = 5
    private static let stopRetryInterval = Duration.seconds(10)
    package static let shutdownTimeout: TimeInterval = 30
    private static let stateChangeTimeout: TimeInterval = 15

    package var name: String { bundle.name }

    package init(
        bundle: VMBundle, host: RunInfo.Host, console: ConsoleMode = .none,
        bootISO: URL? = nil, recovery: Bool = false, headless: Bool = false,
        sharedFolders extraFolders: [SharedFolder] = [],
        managedNetwork: ManagedNetwork? = nil, usbPassthrough: Bool = false, secrets: LoadedSecrets? = nil
    ) throws {
        var config: VMConfig
        let lock: FileLock
        do {
            config = try bundle.loadConfig()
            try Self.checkRunOnlyFolders(extraFolders, for: bundle, config: config)
            config.sharedFolders += extraFolders
            lock = try Self.takeRunLock(of: bundle, host: host)
        } catch {
            managedNetwork?.trafficGuard.stop()
            throw error
        }

        let devices = StartDevices(playsAudio: !headless, usbPassthrough: usbPassthrough)
        let agentInput = Pipe()
        Self.makeNonBlocking(agentInput.fileHandleForWriting)
        let agentOutput = Pipe()
        let machine: Machine
        do {
            machine = try Self.makeMachine(
                bundle: bundle, config: &config, host: host, lock: lock, console: console, bootISO: bootISO,
                devices: devices, agentInput: agentInput, agentOutput: agentOutput, managedNetwork: managedNetwork)
        } catch {
            lock.unlock()
            throw error
        }

        self.bundle = bundle
        self.config = config
        self.runLock = lock
        self.networkLease = machine.lease
        self.trafficGuard = machine.trafficGuard
        self.virtualMachine = machine.virtualMachine
        self.agentInput = agentInput
        self.agentOutput = agentOutput
        self.startUpFromRecovery = recovery
        self.runOnlyFolders = extraFolders
        super.init()

        startReadingAgentReports()
        startWatchingState()
        useSecrets(secrets ?? Self.loadSecrets(of: config))
        try startControlServer()
    }

    private func startReadingAgentReports() {
        agentOutput.fileHandleForReading.readabilityHandler = { [agentReports, weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if agentReports.feed(data) {
                Task { @MainActor in
                    self?.sendTrustLine()
                    self?.startSetupIfDue()
                }
            }
        }
    }

    /// A template's setup commands run once, when the agent first answers; a failed one isn't tried again by itself,
    /// since the steps before it already ran.
    private func startSetupIfDue() {
        guard !isRunningSetup, config.setupRanAt == nil, let steps = config.setup, !steps.isEmpty else { return }
        isRunningSetup = true
        Task { await runSetup(steps) }
    }

    private func runSetup(_ steps: [String]) async {
        var failure: Error?
        do {
            try await SetupSteps.run(steps, os: config.os, in: bundle) { [weak self] index, command in
                Task { @MainActor in self?.setupStatus = "Setting up, \(index + 1) of \(steps.count): \(command)" }
            }
        } catch {
            failure = error
            HangarLog.warning(error.localizedDescription)
        }

        let ranAt = Date()
        config.setupRanAt = ranAt
        do {
            try bundle.updateConfig { $0.setupRanAt = ranAt }
        } catch {
            HangarLog.warning("'\(name)' may run its setup again: \(error.localizedDescription)")
        }
        setupStatus = nil
        isRunningSetup = false
        setupEnded?(failure)
    }

    package typealias LoadedSecrets = Result<SecretsProxyServer.Secrets?, any Error>

    /// Reading the Keychain can wait for the user to allow it, so the app reads them off the main actor before it
    /// makes the session.
    nonisolated package static func loadSecrets(of config: VMConfig) -> LoadedSecrets {
        Result { try SecretsProxyServer.Secrets.load(config.secrets) }
    }

    /// The secrets proxy works only on Hangar's managed network, where the traffic guard sees the guest's packets.
    private func useSecrets(_ loaded: LoadedSecrets) {
        guard let trafficGuard else { return }
        do {
            let secrets = try loaded.get()
            trafficGuard.useSecrets(secrets)
            trustLine = secrets?.trustLine ?? TrustCommand.line(authority: nil, rules: [])
            warnAboutSecretsWithoutValues(using: secrets)
        } catch {
            HangarLog.warning("'\(name)' starts without its secrets: \(error.localizedDescription)")
            trafficGuard.useSecrets(nil)
            trustLine = TrustCommand.line(authority: nil, rules: [])
        }
    }

    private func warnAboutSecretsWithoutValues(using secrets: SecretsProxyServer.Secrets?) {
        let used = Set(secrets?.rules.map(\.name) ?? [])
        let unused = (config.secrets?.rules ?? []).map(\.name).filter { !used.contains($0) }
        guard !unused.isEmpty else { return }
        HangarLog.warning(
            "'\(name)' goes without \(unused.joined(separator: ", ")) until it has a value: give it one in the VM's Secrets or with hangar secret set."
        )
    }

    /// Also to an agent that restarted, so a guest that rebooted gets its certificate and variables back. A full
    /// pipe (the guest isn't reading) drops the line; the agent asks again when it next starts.
    private func sendTrustLine() {
        do {
            try agentInput.fileHandleForWriting.write(contentsOf: Data(trustLine.utf8))
        } catch {
            HangarLog.warning("'\(name)' didn't take its trust settings yet: \(error)")
        }
    }

    package func reloadSecrets() throws {
        config.secrets = try bundle.loadConfig().secrets
        useSecrets(Self.loadSecrets(of: config))
        sendTrustLine()
    }

    private func startWatchingState() {
        virtualMachine.delegate = self
        stateObservation = virtualMachine.observe(\.state, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state = self.virtualMachine.state
            }
        }
    }

    private func startControlServer() throws {
        do {
            controlServer = try ControlServer(
                socketURL: bundle.controlSocketURL,
                exec: { [weak self] request, client in
                    Task { @MainActor in
                        guard let self else {
                            close(client)
                            return
                        }
                        await self.startExec(request, client: client)
                    }
                },
                handler: { [weak self] request in
                    guard let self else { return .failed("The VM's session has closed.") }
                    return await self.handleControl(request)
                }
            )
        } catch {
            trafficGuard?.stop()
            trafficGuard = nil
            networkLease = nil
            runLock.unlock()
            throw error
        }
    }

    package var guestReport: GuestReport? { agentReports.report }

    /// Every VM has the share device, since the Tools folder is always shared; only its folders change.
    package func reloadSharedFolders() throws {
        let saved = try bundle.loadConfig().sharedFolders
        let folders = saved + runOnlyFolders.filter { extra in !saved.contains { $0.name == extra.name } }
        let tag = ConfigurationBuilder.shareTag(for: config.os)
        guard
            let device = virtualMachine.directorySharingDevices
                .compactMap({ $0 as? VZVirtioFileSystemDevice }).first(where: { $0.tag == tag })
        else { throw HangarError("'\(name)' has no shared folder device.") }
        device.share = try ConfigurationBuilder.directoryShare(for: folders, tools: GuestTools.folder(for: config.os))
        config.sharedFolders = folders
    }

    package func attachISO(_ url: URL) async throws {
        guard config.os.supportsISO else {
            throw HangarError(
                "Windows can't read ISOs here: it needs a CD drive, which virtual machines on this Mac don't have.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw HangarError("ISO not found: \(url.path)") }
        guard bundle.runInfo?.liveISO == true, let controller = virtualMachine.usbControllers.first else {
            throw HangarError("Shut down '\(name)' to change its ISO.")
        }

        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
        let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        try await detachISO()
        try await controller.attach(device: device)
    }

    package func detachISO() async throws {
        guard bundle.runInfo?.liveISO == true, let controller = virtualMachine.usbControllers.first else {
            throw HangarError("Shut down '\(name)' to change its ISO.")
        }
        for device in controller.usbDevices where device is VZUSBMassStorageDevice {
            try await controller.detach(device: device)
        }
    }

    package func reloadTrafficPolicy() throws {
        let policy = try bundle.loadConfig().traffic
        try policy.checkRunnable(on: config.network.mode)
        config.traffic = policy
        trafficGuard?.update(policy)
    }

    package func start() async throws {
        do {
            switch config.os {
            case .macOS:
                try await startMac()
            case .linux, .windows:
                try await virtualMachine.start()
            }
            recordFirstStart()
        } catch {
            finish(error)
            throw error
        }
    }

    private func startMac() async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = startUpFromRecovery
        let provisioning = config.provisioning
        if let provisioning {
            try options.setGuestProvisioning(try Self.guestProvisioning(provisioning))
        }

        try await virtualMachine.start(options: options)
        if let provisioning {
            forgetProvisioning(provisioning)
        }
    }

    private static func guestProvisioning(_ provisioning: MacProvisioning) throws -> VZMacGuestProvisioningOptions {
        let guest = VZMacGuestProvisioningOptions()
        guest.fullName = provisioning.fullName
        guest.username = provisioning.username
        guest.password = try provisioning.loadPassword()
        guest.logsInAutomatically = provisioning.autoLogin
        guest.enablesRemoteLogin = provisioning.remoteLogin
        return guest
    }

    private func forgetProvisioning(_ provisioning: MacProvisioning) {
        config.provisioning = nil
        config.sshUser = provisioning.username

        do {
            try bundle.updateConfig {
                $0.provisioning = nil
                $0.sshUser = provisioning.username
            }
            provisioning.forgetPassword()
        } catch {
            HangarLog.warning(
                "Could not remove the one-time account setup from \(bundle.configURL.path): \(error.localizedDescription)."
            )
        }
    }

    private func recordFirstStart() {
        guard config.firstStartedAt == nil else { return }
        let now = Date()
        config.firstStartedAt = now
        do {
            try bundle.updateConfig { $0.firstStartedAt = $0.firstStartedAt ?? now }
        } catch {
            HangarLog.warning(
                "Could not record the first start of \(name) in \(bundle.configURL.path): \(error.localizedDescription)."
            )
        }
    }

    @discardableResult
    package func takeSnapshot(named snapshotName: String) async throws -> VMSnapshot {
        try Snapshots.validate(name: snapshotName, for: bundle)
        guard !isTakingSnapshot else {
            throw HangarError("'\(name)' is already taking a snapshot; try again once that has finished.")
        }

        let wasRunning = virtualMachine.state == .running
        guard wasRunning || virtualMachine.state == .paused else {
            throw HangarError("'\(name)' is \(virtualMachine.state.name); try again once that has finished.")
        }

        isTakingSnapshot = true
        defer { isTakingSnapshot = false }
        if wasRunning { try await virtualMachine.pause() }

        do {
            let snapshot = try await Snapshots.write(bundle, name: snapshotName)
            if wasRunning { try await virtualMachine.resume() }
            return snapshot
        } catch {
            if wasRunning { try? await virtualMachine.resume() }
            throw error
        }
    }

    private func waitForSnapshot() async {
        while isTakingSnapshot {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    package func requestStop() async throws {
        await waitForSnapshot()
        if virtualMachine.state == .paused {
            try await virtualMachine.resume()
        }
        switch config.os {
        case .macOS, .linux:
            // macOS and GNOME answer the power button with a dialog; the agent powers off instead. A
            // guest without the agent still gets the power button.
            try? askAgentToShutDown()
            try virtualMachine.requestStop()
            repeatStopRequestWhileRunning()
        case .windows:
            try askAgentToShutDown()
            try? virtualMachine.requestStop()
            repeatStopRequestWhileRunning()
        }
    }

    /// A guest that never reads its agent port would fill the pipe, and the next write would then block the main
    /// actor and every VM window with it. Such a write fails instead; the agent drops the line it got only part of.
    private static func makeNonBlocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    private func askAgentToShutDown() throws {
        try agentInput.fileHandleForWriting.write(contentsOf: Data("shutdown\n".utf8))
    }

    // A guest that is still booting misses both requests, so they are sent again until it is off.
    private func repeatStopRequestWhileRunning() {
        guard !isRepeatingStopRequest else { return }

        isRepeatingStopRequest = true
        Task {
            defer { isRepeatingStopRequest = false }
            for _ in 1...Self.stopRetries {
                try? await Task.sleep(for: Self.stopRetryInterval)
                guard !hasFinished, virtualMachine.state == .running else { return }
                try? askAgentToShutDown()
                try? virtualMachine.requestStop()
            }
        }
    }

    package func forceStop() async throws {
        switch virtualMachine.state {
        case .stopped, .error:
            break
        default:
            guard virtualMachine.canStop else {
                throw HangarError("'\(name)' is \(virtualMachine.state.name); try again once that has finished.")
            }
            try await virtualMachine.stop()
        }
        finish(nil)
    }

    package func shutdown(timeout: TimeInterval = VMSession.shutdownTimeout) async {
        await waitWhileChangingState(timeout: Self.stateChangeTimeout)

        if (try? await requestStop()) != nil {
            let deadline = Date().addingTimeInterval(timeout)
            while !hasFinished, Date() < deadline {
                try? await Task.sleep(for: Self.pollInterval)
            }
        }

        if !hasFinished {
            await waitWhileChangingState(timeout: Self.stateChangeTimeout)
            do {
                try await forceStop()
            } catch {
                HangarLog.warning("Could not stop '\(name)': \(error.localizedDescription)")
            }
        }
    }

    private func waitWhileChangingState(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasFinished, Date() < deadline,
            isTakingSnapshot
                || [.starting, .pausing, .resuming, .stopping, .saving, .restoring].contains(virtualMachine.state)
        {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    package func pause() async throws {
        await waitForSnapshot()
        guard virtualMachine.state != .paused else {
            throw HangarError("'\(name)' is already paused.")
        }
        guard virtualMachine.canPause else {
            throw HangarError("'\(name)' is \(virtualMachine.state.name), so it can't be paused.")
        }
        try await virtualMachine.pause()
    }

    package func resume() async throws {
        await waitForSnapshot()
        guard virtualMachine.canResume else {
            throw HangarError("'\(name)' is \(virtualMachine.state.name), not paused.")
        }
        try await virtualMachine.resume()
    }

    private func finish(_ error: Error?) {
        guard !hasFinished else { return }

        hasFinished = true
        stopError = error
        state = virtualMachine.state
        controlServer?.invalidate()
        controlServer = nil
        agentOutput.fileHandleForReading.readabilityHandler = nil
        trafficGuard?.stop()
        trafficGuard = nil
        networkLease = nil
        runLock.unlock()
        didStop?(error)
        didStop = nil
    }

}

extension VMSession: VZVirtualMachineDelegate {
    nonisolated package func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated package func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated package func virtualMachine(
        _ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        MainActor.assumeIsolated { networkError = error.localizedDescription }
    }
}
