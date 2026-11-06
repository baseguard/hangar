import AppKit
import Foundation
import HangarKit
import HangarPackets
import HangarSupport
import HangarTraffic
import Observation
import Virtualization

struct StoreAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
final class VMStore {
    static let shared = VMStore()

    private(set) var vms: [VMItem] = []
    private(set) var sessions: [String: VMSession] = [:]
    private(set) var jobs: [CreationJob] = []
    private(set) var busy: Set<String> = []
    private(set) var startingNetwork: Set<String> = []
    private(set) var network: SharedNetwork.State?
    private(set) var subnet = SharedNetwork.subnet
    private(set) var usage: [String: VMUsage] = [:]
    private(set) var usageHistory: [String: [UsageSample]] = [:]
    private(set) var unreadable: [VMBundle: String] = [:]
    private(set) var finishedJobs: [UUID: String] = [:]
    private(set) var alerts: [StoreAlert] = []
    /// Set by the first scan of the library, so a picker shown at launch doesn't mistake "not read yet" for empty.
    private(set) var hasScanned = false
    var request: MainWindowRequest?
    /// Files shared to Hangar (Finder's Share menu, or opened with it) that wait for the user to pick a VM.
    var dropRequest: DropRequest?

    private var jobTasks: [UUID: Task<Void, Never>] = [:]
    private var saving: Task<Void, Never>?
    private var refreshing = false
    private var lastLocalChange = Date.distantPast
    private var refreshAgain = false
    private(set) var dropStatus: [String: String] = [:]
    private(set) var copies: [String: FileCopy] = [:]
    private var copyTasks: [String: Task<Void, Never>] = [:]
    /// Downloads and uploads that Files windows run; quitting would cut them short too.
    var runningFileTransfers = 0
    /// Running updates of guest agents: what each is doing, shown in that VM's windows, and its task for Cancel.
    var agentUpdates: [String: AgentUpdate] = [:]

    /// VMs started in their own process, which carry on when Hangar quits.
    private var launchingInBackground: Set<String> = []

    static let usageWindow: TimeInterval = 180
    static let copyProgressDelay = Duration.seconds(1)
    nonisolated private static let usageMonitor = UsageMonitor()

    private init() {
        refresh()
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: refreshInterval)
                refresh()
            }
        }
    }

    /// Every 2 s while a Hangar window shows the library; the menu bar menu alone only needs it now and then.
    private var refreshInterval: Duration {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } ? .seconds(2) : .seconds(10)
    }

    func vm(_ name: String?) -> VMItem? {
        vms.first { $0.name == name }
    }

    func uniqueName(_ base: String) -> String {
        var candidate = base
        var index = 2
        while nameIsTaken(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    /// The one check behind every VM name field, so each problem is told in the same words everywhere.
    func nameProblem(_ name: String, ignoring current: String? = nil) -> String? {
        if name.isEmpty { return "Enter a name." }
        guard VMLibrary.isValidName(name) else { return VMLibrary.nameRule }
        guard !nameIsTaken(name, ignoring: current) else { return "There's already a VM named “\(name)”." }
        return nil
    }

    func nameIsTaken(_ name: String, ignoring current: String? = nil) -> Bool {
        let lowered = name.lowercased()
        guard lowered != current?.lowercased() else { return false }
        return vms.contains { $0.name.lowercased() == lowered } || jobs.contains { $0.name.lowercased() == lowered }
    }

    func ask(_ kind: MainWindowRequest.Kind) {
        request = MainWindowRequest(kind: kind)
        MainWindow.show()
    }

    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }

        refreshing = true
        let startedAt = Date()
        Task {
            let scan = await Self.scan()
            refreshing = false
            defer {
                if refreshAgain {
                    refreshAgain = false
                    refresh()
                }
            }

            let items = scan.items.map { scanned in
                var item = scanned
                if let session = sessions[item.name] {
                    item.state = MachineState(session.state)
                }
                return item
            }

            if startedAt > lastLocalChange, vms != items { vms = items }
            if !hasScanned { hasScanned = true }
            if network != scan.network { network = scan.network }
            // A VM started in the background takes minutes to report running; its network is up long before.
            if scan.network != nil, !startingNetwork.isEmpty { startingNetwork.removeAll() }
            if subnet != scan.subnet { subnet = scan.subnet }
            if unreadable != scan.unreadable { unreadable = scan.unreadable }
            if usage != scan.usage { usage = scan.usage }
            recordUsage()
        }
    }

    private func recordUsage() {
        let now = Date()
        var history: [String: [UsageSample]] = [:]
        for vm in vms {
            guard let usage = usage[vm.name], let cpu = usage.cpuShare(of: vm.config.cpuCount) else {
                if vm.isRunning, let kept = usageHistory[vm.name] { history[vm.name] = kept }
                continue
            }

            let samples = (usageHistory[vm.name] ?? []).filter { now.timeIntervalSince($0.date) < Self.usageWindow }
            history[vm.name] =
                samples + [
                    UsageSample(
                        date: now, cpu: cpu, memory: usage.memory, guestMemory: usage.guestMemory?.used,
                        diskRead: usage.diskRead ?? 0, diskWrite: usage.diskWrite ?? 0)
                ]
        }
        if usageHistory != history { usageHistory = history }
    }

    nonisolated private struct Scan: Sendable {
        var items: [VMItem]
        var network: SharedNetwork.State?
        var subnet: IPv4Subnet
        var unreadable: [VMBundle: String]
        var usage: [String: VMUsage]
    }

    @concurrent
    nonisolated private static func scan() async -> Scan {
        var unreadable: [VMBundle: String] = [:]
        let items: [VMItem] = VMLibrary.all().compactMap { bundle in
            let config: VMConfig
            do {
                config = try bundle.loadConfig()
            } catch {
                unreadable[bundle] = error.localizedDescription
                return nil
            }

            let run = bundle.runInfo
            var state = MachineState.stopped
            if run != nil {
                state = ControlClient.runningState(of: bundle)
            }
            return VMItem(
                bundle: bundle, config: config, run: run, state: state,
                ip: run.flatMap { IPResolver.ipAddress(for: config, startedAt: $0.startedAt) },
                diskSize: bundle.diskSize, diskUsed: bundle.allocatedSize,
                snapshots: bundle.snapshots
            )
        }

        let usage = sampleUsage(of: items)
        return Scan(
            items: items, network: SharedNetwork.state, subnet: SharedNetwork.subnet,
            unreadable: unreadable, usage: usage)
    }

    nonisolated private static func sampleUsage(of items: [VMItem]) -> [String: VMUsage] {
        var usage: [String: VMUsage] = [:]
        guard items.contains(where: \.isRunning) else { return usage }

        let sampled = usageMonitor.sample()
        for item in items where item.isRunning {
            usage[item.name] = sampled[item.name]
            if case .report(let report?)? = try? ControlClient.send(.memory, to: item.bundle, timeout: 1) {
                usage[item.name]?.guestMemory = report.memory
                usage[item.name]?.agentVersion = report.agentVersion
                usage[item.name]?.hasScreen = report.hasScreen
            }
        }
        return usage
    }

    func start(_ name: String, recovery: Bool = false, then openDisplay: @escaping (String) -> Void) {
        if let twin = twin(of: name) {
            VMDialog.separate(TwinStart(vm: name, twin: twin, recovery: recovery, inBackground: false)).post()
            return
        }
        guard beginBusy(name, doing: "start \(name)") else { return }
        Task {
            defer {
                startingNetwork.remove(name)
                endBusy(name)
            }
            do {
                let bundle = try VMLibrary.bundle(named: name)
                // Read off the main actor; the session itself waits up to half a second for a held run lock, and the
                // Keychain can wait for the user to allow access to the secrets.
                let (config, isRunning, isNetworkUp, secrets) = try await runInBackground {
                    let config = try bundle.loadConfig()
                    return (config, bundle.isRunning, SharedNetwork.isDaemonRunning, VMSession.loadSecrets(of: config))
                }
                guard !isRunning else { throw VMSession.alreadyRunning(name) }

                if config.network.mode == .managed, !isNetworkUp { startingNetwork.insert(name) }
                let network =
                    config.network.mode == .managed
                    ? try await runInBackground { try VMSession.setUpManagedNetwork(for: bundle) }
                    : nil
                startingNetwork.remove(name)

                let session = try makeSession(
                    name, bundle: bundle, recovery: recovery, network: network, secrets: secrets)
                sessions[name] = session
                USBDevices.shared.startListening()
                openDisplay(name)
                try? await session.start()
            } catch {
                report(error, doing: "start \(name)")
            }
        }
    }

    func startInBackground(_ name: String) {
        if let twin = twin(of: name) {
            VMDialog.separate(TwinStart(vm: name, twin: twin, recovery: false, inBackground: true)).post()
            return
        }
        guard beginBusy(name, doing: "start \(name)") else { return }
        Task { await launchInBackground(name) }
    }

    /// The other VM that `name` was copied from or to outside Hangar, read from the configs the library scan loaded.
    func twin(of name: String) -> String? {
        guard let item = vm(name) else { return nil }
        return vms.first { $0.name != name && VMLibrary.sharesIdentity(item.config, $0.config) }?.name
    }

    /// Gives the VM what Clone gives a copy, then starts it the way the user first asked.
    func separateAndStart(_ request: TwinStart, as newName: String, then openDisplay: @escaping (String) -> Void) {
        guard let item = vm(request.vm) else { return }
        let action = "make \(request.vm) a separate VM"
        guard beginBusy(request.vm, doing: action) else { return }
        Task {
            do {
                let (separated, config) = try await runInBackground {
                    let separated = try VMLibrary.separate(item.bundle, as: newName)
                    return (separated, try separated.loadConfig())
                }
                replace(request.vm, with: separated, config: config)
                endBusy(request.vm)
                startSeparated(separated.name, as: request, then: openDisplay)
            } catch {
                endBusy(request.vm)
                report(error, doing: action)
            }
        }
    }

    /// The library scan would show the new name and identity only a moment later, and a start checks for twins
    /// against what the store holds.
    private func replace(_ name: String, with bundle: VMBundle, config: VMConfig) {
        guard let index = vms.firstIndex(where: { $0.name == name }) else { return }
        vms[index].bundle = bundle
        vms[index].config = config
        vms[index].snapshots = bundle.snapshots
        lastLocalChange = Date()
        if bundle.name != name {
            NotificationCenter.default.post(VirtualMachineRenamedMessage(oldName: name, newName: bundle.name))
        }
    }

    private func startSeparated(_ name: String, as request: TwinStart, then openDisplay: @escaping (String) -> Void) {
        if request.inBackground {
            startInBackground(name)
        } else {
            start(name, recovery: request.recovery, then: openDisplay)
        }
    }

    func startAutoStartVMs() {
        Task {
            let names = await runInBackground { VMLibrary.stoppedAutoStartVMs().map(\.name) }
            // Side by side, so one VM that hangs while starting doesn't hold up the others.
            await withTaskGroup { group in
                for name in names {
                    guard beginBusy(name, doing: "start \(name)") else { continue }
                    group.addTask { await self.launchInBackground(name) }
                }
            }
        }
    }

    /// The caller has marked `name` busy, so a delete or another start can't slip in before this runs.
    private func launchInBackground(_ name: String) async {
        launchingInBackground.insert(name)
        if vm(name)?.config.network.mode == .managed, !SharedNetwork.isDaemonRunning { startingNetwork.insert(name) }
        defer {
            launchingInBackground.remove(name)
            startingNetwork.remove(name)
            endBusy(name)
        }
        do {
            _ = try await runInBackground { try VMLibrary.bundle(named: name).startInBackground() }
        } catch {
            report(error, doing: "start \(name)")
        }
    }

    func shutdown(_ name: String) {
        perform(.stop, on: name, doing: "shut down")
    }

    func openSSH(_ name: String) {
        guard let vm = vm(name), let ip = vm.ip else { return }
        var components = URLComponents()
        components.scheme = "ssh"
        components.user = vm.config.loginUser
        components.host = ip
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            report(HangarError("No app on this Mac opens ssh:// links."), doing: "open Terminal")
            return
        }
    }

    func openRemoteDesktop(_ name: String) {
        guard let vm = vm(name), let ip = vm.ip else { return }
        do {
            try RemoteDesktop.open(name: name, config: vm.config, address: ip)
        } catch {
            report(error, doing: "open Remote Desktop")
        }
    }

    func forceStop(_ name: String) {
        perform(.forceStop, on: name, doing: "stop")
    }

    func pause(_ name: String) {
        perform(.pause, on: name, doing: "pause")
    }

    func resume(_ name: String) {
        perform(.resume, on: name, doing: "resume")
    }

    private func perform(_ request: ControlRequest, on name: String, doing verb: String) {
        Task {
            do {
                try await send(request, to: name)
            } catch {
                report(error, doing: "\(verb) \(name)")
            }
            refresh()
        }
    }

    /// A VM running in this app is told directly: asking it through its control socket would wait on this actor. A VM
    /// that isn't running has nothing to be told.
    func send(_ request: ControlRequest, to name: String) async throws {
        if let session = sessions[name] {
            if case .failed(let message) = await session.handleControl(request) { throw HangarError(message) }
            return
        }
        let bundle = try VMLibrary.bundle(named: name)
        try await runInBackground {
            guard bundle.isRunning else { return }
            _ = try ControlClient.send(request, to: bundle)
        }
    }

    /// Creations, copies and other library work, such as an export, that quitting would cut short.
    var unfinishedWork: Int {
        let libraryWork = busy.subtracting(sessions.keys).subtracting(launchingInBackground)
        return jobs.count { $0.error == nil } + copyTasks.count + runningFileTransfers + libraryWork.count
    }

    /// False when the copy didn't start: no files, no such VM, or a copy into it still running, which is reported.
    @discardableResult
    func dropFiles(_ urls: [URL], into name: String) -> Bool {
        let files = GuestDrop.localFiles(urls)
        guard !files.isEmpty, let vm = vmTakingCopy(named: name) else { return false }

        let title = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items"
        dropStatus[name] = "Copying \(title)…"
        copyTasks[name] = Task { await copy(files, titled: title, into: vm) }
        return true
    }

    /// Says why a VM can't take a copy now: it is gone, or a copy into it is still running.
    private func vmTakingCopy(named name: String) -> VMItem? {
        guard let vm = vm(name) else {
            report(HangarError("There's no VM named '\(name)' any more."), doing: "copy the files into \(name)")
            return nil
        }
        guard copyTasks[name] == nil else {
            let error = HangarError("'\(name)' is still copying files; drop these when that copy is done.")
            report(error, doing: "copy the files into \(name)")
            return nil
        }
        return vm
    }

    private func copy(_ files: [URL], titled title: String, into vm: VMItem) async {
        let name = vm.name
        let bundle = vm.bundle
        let started = ContinuousClock.now
        do {
            try await drop(files, into: bundle) { copied, total in
                Task { @MainActor in
                    self.showCopy(into: name, title: title, copied: copied, total: total, since: started)
                }
            }
            endCopy(into: name)
            dropStatus[name] = "Copied to HangarDrop in the home folder of \(name)"
            await clearDropStatus(of: name, after: .seconds(5))
        } catch {
            endCopy(into: name)
            dropStatus[name] = nil
            if !(error is CancellationError) { report(error, doing: "copy the files into \(name)") }
        }
    }

    /// Cancelling the copy's task ends it at once, even on a guest that stopped answering.
    private func drop(_ files: [URL], into bundle: VMBundle, progress: @escaping GuestDrop.Progress) async throws {
        let stop = CopyStop()
        try await withTaskCancellationHandler {
            try await runInBackground { try GuestDrop.drop(files, into: bundle, stop: stop, progress: progress) }
        } onCancel: {
            stop.stop()
        }
    }

    /// Unless a newer message has replaced it by then.
    private func clearDropStatus(of name: String, after delay: Duration) async {
        let shown = dropStatus[name]
        try? await Task.sleep(for: delay)
        if dropStatus[name] == shown { dropStatus[name] = nil }
    }

    /// Never drops on its own: the files wait until the user picks a VM.
    func askWhereToDrop(_ urls: [URL]) {
        let files = GuestDrop.localFiles(urls)
        guard !files.isEmpty else { return }
        dropRequest = DropRequest(files: files)
        DropWindow.show()
    }

    func isCopying(into name: String) -> Bool {
        copyTasks[name] != nil
    }

    func cancelCopy(into name: String) {
        copyTasks[name]?.cancel()
    }

    private func showCopy(
        into name: String, title: String, copied: UInt64, total: UInt64, since started: ContinuousClock.Instant
    ) {
        guard copyTasks[name] != nil, copies[name] != nil || ContinuousClock.now - started >= Self.copyProgressDelay
        else { return }
        copies[name] = FileCopy(vm: name, title: title, copied: copied, total: total)
    }

    private func endCopy(into name: String) {
        copyTasks[name] = nil
        copies[name] = nil
    }

    /// A session whose stop and setup outcomes come back to the store.
    private func makeSession(
        _ name: String, bundle: VMBundle, recovery: Bool, network: VMSession.ManagedNetwork?,
        secrets: VMSession.LoadedSecrets?
    ) throws -> VMSession {
        let session = try VMSession(
            bundle: bundle, host: .app, recovery: recovery, managedNetwork: network,
            usbPassthrough: true, secrets: secrets)
        session.didStop = { [self] error in
            sessionStopped(name, error: error)
        }
        session.setupEnded = { [self] error in
            if let error { report(error, doing: "set up \(name)") }
        }
        return session
    }

    private func sessionStopped(_ name: String, error: Error?) {
        sessions[name] = nil
        USBDevices.shared.forget(vm: name)
        if sessions.isEmpty { USBDevices.shared.stopListening() }
        if let error {
            report(error, doing: "run \(name)")
        }
        refresh()
    }

    func shutdownHostedVMs() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                group.addTask { await session.shutdown(timeout: 20) }
            }
        }
    }

    func delete(_ name: String) {
        whileBusy(name, doing: "delete \(name)") { bundle in
            try await runInBackground { try VMLibrary.delete(bundle) }
        }
    }

    @discardableResult
    func rename(_ name: String, to newName: String) async -> Bool {
        guard name != newName else { return true }
        guard beginBusy(name, doing: "rename \(name)") else { return false }
        defer { endBusy(name) }
        do {
            await saved()
            try await runInBackground { try VMLibrary.rename(try VMLibrary.bundle(named: name), to: newName) }
            if let index = vms.firstIndex(where: { $0.name == name }) {
                let renamed = VMBundle(url: HangarPaths.vms.appendingPathComponent(newName, isDirectory: true))
                vms[index].bundle = renamed
                vms[index].snapshots = renamed.snapshots
                lastLocalChange = Date()
            }
            NotificationCenter.default.post(VirtualMachineRenamedMessage(oldName: name, newName: newName))
            refresh()
            return true
        } catch {
            report(error, doing: "rename \(name)")
            return false
        }
    }

    func clone(_ name: String, snapshot: VMSnapshot? = nil, as newName: String) {
        guard beginBusy(name, doing: "clone \(name)") else { return }
        Task {
            defer { endBusy(name) }
            do {
                if let snapshot {
                    try await VMLibrary.clone(snapshot, as: newName)
                } else {
                    try await VMLibrary.clone(try VMLibrary.bundle(named: name), as: newName)
                }
            } catch {
                report(error, doing: "clone \(name)")
            }
        }
    }

    func takeSnapshot(of name: String, named snapshotName: String) {
        guard beginBusy(name, doing: "take a snapshot of \(name)") else { return }
        Task {
            defer { endBusy(name) }
            do {
                if let session = sessions[name] {
                    try await session.takeSnapshot(named: snapshotName)
                } else {
                    let bundle = try VMLibrary.bundle(named: name)
                    _ = try await Snapshots.take(of: bundle, name: snapshotName)
                }
            } catch {
                report(error, doing: "take a snapshot of \(name)")
            }
        }
    }

    func restoreSnapshot(_ snapshot: VMSnapshot, of name: String) {
        whileBusy(name, doing: "restore \(name)") { bundle in
            try await runInBackground { try Snapshots.restore(snapshot, to: bundle) }
        }
    }

    func renameSnapshot(_ snapshot: VMSnapshot, of name: String, to newName: String) {
        whileBusy(name, doing: "rename the snapshot") { bundle in
            _ = try await runInBackground { try Snapshots.rename(snapshot, of: bundle, to: newName) }
        }
    }

    func deleteSnapshot(_ snapshot: VMSnapshot, of name: String) {
        whileBusy(name, doing: "delete the snapshot") { _ in
            try await runInBackground { try Snapshots.delete(snapshot) }
        }
    }

    private func whileBusy(_ name: String, doing action: String, _ work: @escaping (VMBundle) async throws -> Void) {
        guard beginBusy(name, doing: action) else { return }
        Task {
            defer { endBusy(name) }
            do {
                try await work(try VMLibrary.bundle(named: name))
            } catch {
                report(error, doing: action)
            }
        }
    }

    /// Also for work that runs outside the store, like an export. An action on a VM that is busy already is
    /// refused out loud, so the user knows why nothing happened.
    func beginBusy(_ name: String, doing action: String) -> Bool {
        guard !busy.contains(name) else {
            report(HangarError("'\(name)' is busy with another task; try again when it has finished."), doing: action)
            return false
        }
        busy.insert(name)
        return true
    }

    func endBusy(_ name: String) {
        busy.remove(name)
        refresh()
    }

    /// `appliedLive`: the running session has taken this change already, or picks it up itself.
    @discardableResult
    func update(
        _ name: String, appliedLive: Bool = false, _ change: @escaping @Sendable (inout VMConfig) throws -> Void
    ) -> Bool {
        guard let index = vms.firstIndex(where: { $0.name == name }) else { return false }
        let old = vms[index].config
        var preview = old
        do {
            try change(&preview)
            if vms[index].isRunning, !appliedLive, VMSettings.needsStoppedVM(from: old, to: preview) {
                throw VMBundle.stillRunning(name)
            }
            try VMSettings.check(from: old, to: preview)
        } catch {
            report(error, doing: "update \(name)")
            return false
        }

        vms[index].config = preview
        lastLocalChange = Date()
        let previous = saving
        saving = Task {
            await previous?.value
            await save(name, appliedLive: appliedLive, change)
        }
        return true
    }

    func saved() async {
        await saving?.value
    }

    private func save(
        _ name: String, appliedLive: Bool, _ change: @escaping @Sendable (inout VMConfig) throws -> Void
    ) async {
        do {
            let config = try await runInBackground {
                try VMSettings.change(VMLibrary.bundle(named: name), appliedLive: appliedLive, change)
            }
            if let index = vms.firstIndex(where: { $0.name == name }), vms[index].config != config {
                vms[index].config = config
            }
            lastLocalChange = Date()
        } catch {
            report(error, doing: "update \(name)")
        }
        refresh()
    }

    func growDisk(_ name: String, to bytes: UInt64) {
        whileBusy(name, doing: "grow the disk of \(name)") { bundle in
            try await runInBackground { try VMLibrary.withStoppedVM(bundle) { try bundle.resizeDisk(to: bytes) } }
        }
    }

    @discardableResult
    func updateTraffic(_ name: String, _ change: @escaping @Sendable (inout TrafficPolicy) throws -> Void) -> Bool {
        guard update(name, appliedLive: true, { config in try change(&config.traffic) }) else { return false }
        Task {
            do {
                await saved()
                try await send(.reloadTrafficRules, to: name)
            } catch {
                report(error, doing: "apply the traffic rules to \(name)")
            }
        }
        return true
    }

    @discardableResult
    /// A VM made from a template is set up from it once it is made, with the secret values given by name.
    func create(
        name: String, source: VMSource, options: CreateOptions, template: VMTemplate? = nil,
        secretValues: [String: String] = [:], startingWith openDisplay: ((String) -> Void)? = nil
    ) -> UUID {
        let job = CreationJob(name: name, source: source, options: options, openDisplay: openDisplay)
        jobs.append(job)
        let id = job.id
        let report: ProgressHandler = { progress in
            Task { @MainActor in VMStore.shared.updateJob(id, progress) }
        }

        jobTasks[id] = Task {
            do {
                let bundle = try await source.createVM(named: name, options: options, progress: report)
                if let template { await setUp(bundle, from: template, secretValues: secretValues) }
                finishedJobs[id] = name
                jobs.removeAll { $0.id == id }
                if let openDisplay {
                    refresh()
                    start(name, then: openDisplay)
                }
            } catch {
                if let index = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[index].error = error is CancellationError ? "Cancelled." : error.localizedDescription
                }
            }
            jobTasks[id] = nil
            refresh()
        }
        return id
    }

    /// The VM is made by now, so a failure here is told on its own instead of failing the job.
    private func setUp(_ bundle: VMBundle, from template: VMTemplate, secretValues: [String: String]) async {
        do {
            _ = try await runInBackground { try template.setUp(bundle, secretValues: secretValues) }
        } catch {
            report(error, doing: "set up \(bundle.name) from its template")
        }
    }

    func cancelJob(_ id: UUID) {
        jobTasks[id]?.cancel()
        jobs.removeAll { $0.id == id }
    }

    @discardableResult
    func retryJob(_ id: UUID) -> UUID? {
        guard let job = jobs.first(where: { $0.id == id }) else { return nil }
        jobs.removeAll { $0.id == id }
        return create(name: job.name, source: job.source, options: job.options, startingWith: job.openDisplay)
    }

    private func updateJob(_ id: UUID, _ progress: CreationProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].error == nil else { return }
        jobs[index].progress = progress
    }

    func dismissJob(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    var alert: StoreAlert? { alerts.first }

    /// By id: two windows can show the same alert, and the second dismissal must not take the next one.
    func dismissAlert(_ id: StoreAlert.ID) {
        alerts.removeAll { $0.id == id }
    }

    func report(_ error: Error, doing action: String) {
        alerts.append(StoreAlert(title: "Couldn't \(action)", message: error.localizedDescription))
        // After the action that failed has returned; a modal alert inside it would run the run loop again.
        Task { WindowlessAlerts.showIfNoWindow(for: self) }
    }
}
