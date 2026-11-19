import AppKit
import HangarKit
import HangarSupport
import Observation

/// Whether a newer Hangar is out, and getting it: checked shortly after launch and twice a day while the setting is
/// on, downloaded when the user asks, and put in place when Hangar quits.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()
    static let automaticChecksKey = "checksForUpdates"
    private static let firstCheckDelay = Duration.seconds(20)
    private static let checkInterval = Duration.seconds(12 * 60 * 60)

    enum State {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, CreationProgress?)
        case ready(AppRelease, staged: URL)
        case failed(String)
    }

    private(set) var state = State.idle
    let runningVersion = AppVersion.running
    /// Quitting to update opens Hangar again; quitting otherwise installs the update without opening it.
    @ObservationIgnored private var relaunchesAfterInstall = false
    @ObservationIgnored private var regularChecks: Task<Void, Never>?

    /// A build that wasn't released has no version to compare with.
    var canUpdate: Bool { runningVersion?.isRelease == true }

    /// The release the badges show: one that is out, downloading or ready to install.
    var newRelease: AppRelease? {
        switch state {
        case .available(let release), .downloading(let release, _), .ready(let release, _): release
        case .idle, .checking, .upToDate, .failed: nil
        }
    }

    private var installedApp: URL { Bundle.main.bundleURL }

    private var checksAutomatically: Bool {
        UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    func start() {
        guard canUpdate, regularChecks == nil else { return }
        AppUpdate.removeLeftovers(nextTo: installedApp)
        regularChecks = Task { await checkRegularly() }
    }

    private func checkRegularly() async {
        try? await Task.sleep(for: Self.firstCheckDelay)
        while !Task.isCancelled {
            if checksAutomatically { await check() }
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    /// A release already found stays, so a check never interrupts a download or an update waiting to install; one
    /// check at a time, and its answer counts only if nothing started meanwhile.
    func check() async {
        guard canUpdate, let runningVersion, newRelease == nil, !isChecking else { return }
        state = .checking
        let answer: State
        do {
            let release = try await AppRelease.latest()
            answer = release.version > runningVersion ? .available(release) : .upToDate
        } catch {
            answer = .failed(error.localizedDescription)
        }
        guard isChecking else { return }
        state = answer
    }

    /// Downloads and checks the release, then asks to relaunch.
    func download() {
        guard case .available(let release) = state else { return }
        state = .downloading(release, nil)
        Task { await prepare(release) }
    }

    private func prepare(_ release: AppRelease) async {
        do {
            let staged = try await AppUpdate.prepare(release, replacing: installedApp) { progress in
                Task { @MainActor in self.show(progress, of: release) }
            }
            state = .ready(release, staged: staged)
            onMainRunLoop { if UpdateAlerts.askToRelaunch(for: release) { self.relaunchToUpdate() } }
        } catch {
            state = .available(release)
            VMStore.shared.report(error, doing: "update Hangar")
        }
    }

    private func show(_ progress: CreationProgress, of release: AppRelease) {
        guard case .downloading(let current, _) = state, current == release else { return }
        state = .downloading(release, progress)
    }

    /// Quits as the user would, so the questions about running VMs and unfinished work come first; Hangar is
    /// replaced only if it really quits.
    func relaunchToUpdate() {
        guard case .ready = state else { return }
        relaunchesAfterInstall = true
        NSApp.terminate(nil)
        // terminate returns only when the quit was cancelled.
        relaunchesAfterInstall = false
    }

    /// As Hangar quits, a downloaded update takes the old app's place. Hangar's network stops too when no VM uses it,
    /// so the next VM starts the new version's network.
    func installOnQuit() {
        guard case .ready(_, let staged) = state else { return }
        do {
            try AppUpdate.install(staged, replacing: installedApp)
            SharedNetwork.stopDaemonIfUnused()
            if relaunchesAfterInstall { try AppUpdate.relaunch(installedApp) }
        } catch {
            HangarLog.warning(error.localizedDescription)
        }
    }
}
