import Foundation
import HangarDisks
import HangarSupport
import Virtualization

package enum WindowsInstaller {
    /// Unattended setup takes well under an hour; longer means it stopped at a dialog.
    static let installTimeout: TimeInterval = 45 * 60
    private static let progressInterval = Duration.seconds(1)

    package struct Account: Sendable {
        package var username: String
        package var password: String
        package var remoteDesktop: Bool

        package init(username: String, password: String, remoteDesktop: Bool = true) {
            self.username = username
            self.password = password
            self.remoteDesktop = remoteDesktop
        }

        package func validate(forVM name: String) throws {
            guard username.wholeMatch(of: /[A-Za-z][A-Za-z0-9_.-]{0,19}/) != nil else {
                throw HangarError(
                    "Windows user names have up to 20 letters, digits, '.', '_' or '-', starting with a letter.")
            }
            guard !password.isEmpty else { throw HangarError("Enter a password for the Windows account.") }
            let reserved = [
                "administrator", "administrators", "guest", "guests", "users", "defaultaccount",
                "wdagutilityaccount", WindowsInstaller.computerName(for: name).lowercased(),
            ]
            guard !reserved.contains(username.lowercased()) else {
                throw HangarError("'\(username)' is a name Windows reserves; choose another user name.")
            }
        }
    }

    static let driversURL = URL(
        constant:
            "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"
    )
    static let driversDigest = "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    static let winFspURL = URL(constant: "https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi")
    static let winFspDigest = "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, iso: URL, account: Account, options: CreateOptions,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        guard WindowsPlatform.isSupported else {
            throw HangarError("This version of macOS cannot run Windows on Virtualization.framework.")
        }
        try account.validate(forVM: name)
        let support = try await downloadSupportFiles(progress: progress)

        return try await VMLibrary.create(name: name) { staging in
            try SparseFile.create(at: staging.diskURL, size: options.diskSize)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: staging.nvramURL, options: [])
            var config = try VMConfig.newVM(.windows, options: options)
            config.sshUser = account.username
            config.remoteDesktop = account.remoteDesktop
            try staging.saveConfig(config)

            let media = staging.url.appendingPathComponent("install.img")
            defer { try? FileManager.default.removeItem(at: media) }
            try await makeInstallMedia(
                at: media, iso: iso, support: support, computerName: computerName(for: name), account: account,
                progress: progress)
            try await runInstaller(bundle: staging, config: config, media: media, progress: progress)
            try WindowsMedia.checkResult(media)
        }
    }

    private static func downloadSupportFiles(
        progress: @escaping ProgressHandler
    ) async throws -> (drivers: URL, winFsp: URL) {
        let drivers = try await Downloader.cached(
            driversURL, as: HangarPaths.isoCache.appendingPathComponent(driversURL.lastPathComponent),
            digest: driversDigest, phase: "Downloading Windows drivers", progress: progress)
        let winFsp = try await Downloader.cached(
            winFspURL, as: HangarPaths.isoCache.appendingPathComponent(winFspURL.lastPathComponent),
            digest: winFspDigest, phase: "Downloading WinFsp", progress: progress)
        return (drivers, winFsp)
    }

    private static func makeInstallMedia(
        at media: URL, iso: URL, support: (drivers: URL, winFsp: URL), computerName: String, account: Account,
        progress: @escaping ProgressHandler
    ) async throws {
        let mediaLock = FileLock(url: HangarPaths.isoCache.appendingPathComponent("windows-media.lock"))
        try await mediaLock.lockWaiting(
            "Waiting for another Windows VM to finish its installation media", progress: progress)
        defer { mediaLock.unlock() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    with: Result {
                        try WindowsMedia.create(
                            at: media, windowsISO: iso, driversISO: support.drivers, winFsp: support.winFsp,
                            computerName: computerName, account: account, progress: progress)
                    })
            }
        }
    }

    @MainActor
    private static func runInstaller(
        bundle: VMBundle, config: VMConfig, media: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let configuration = try ConfigurationBuilder(
            bundle: bundle, config: config, purpose: .install,
            windowsInstallMedia: media
        ).build()
        let vm = VZVirtualMachine(configuration: configuration)
        let watcher = StopWatcher()
        vm.delegate = watcher
        try await vm.start()

        let started = Date()
        while !watcher.stopped {
            let elapsed = Date().timeIntervalSince(started)
            if Task.isCancelled || elapsed > Self.installTimeout {
                if vm.canStop { try? await vm.stop() }
                throw HangarError(
                    Task.isCancelled
                        ? "Windows installation was cancelled."
                        : "Windows installation did not finish in \(Int(Self.installTimeout / 60)) minutes.")
            }
            progress(
                CreationProgress(phase: "Installing Windows", detail: "\(Int(elapsed) / 60) min \(Int(elapsed) % 60) s")
            )
            try? await Task.sleep(for: Self.progressInterval)
        }
        if let error = watcher.error {
            throw HangarError("The Windows installer stopped with an error: \(error.localizedDescription)")
        }
    }

    private final class StopWatcher: NSObject, VZVirtualMachineDelegate {
        var stopped = false
        var error: Error?

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            stopped = true
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            self.error = error
            stopped = true
        }
    }

    static func computerName(for name: String) -> String {
        let dashes = CharacterSet(charactersIn: "-")
        var cleaned = String(name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .trimmingCharacters(in: dashes)
        if !cleaned.contains(where: \.isLetter) { cleaned = "WIN-" + cleaned }
        cleaned = String(cleaned.prefix(15)).trimmingCharacters(in: dashes)
        return cleaned.count < 2 || cleaned == "WIN" ? "HANGAR-VM" : cleaned
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func component(_ name: String) -> String {
        "component name=\"\(name)\" processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\""
    }
}
