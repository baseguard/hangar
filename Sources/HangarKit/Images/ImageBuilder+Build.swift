import Foundation
import HangarSupport

extension ImageBuilder {
    /// Builds image-<kind> and leaves it shut down. `prepare` puts the first-start job into the clone's disk as
    /// root; the command line decides how it becomes root, so the kit never does.
    @MainActor
    package static func build(
        _ kind: Kind, ipsw: String, prepare: (VMBundle) throws -> Void, progress: @escaping ProgressHandler
    ) async throws -> (VMBundle, MacOS) {
        guard kind != .vanilla else { return try await buildVanilla(ipsw: ipsw, progress: progress) }
        let sourceName = kind == .base ? Kind.vanilla.vmName : Kind.base.vmName
        let source = try VMLibrary.bundle(named: sourceName)
        let macOS = try macOS(of: source)
        let bundle = try await VMLibrary.clone(source, as: kind.vmName)
        try record(macOS, in: bundle)
        if kind == .base { try giveAccount(to: bundle) }

        try prepare(bundle)
        try await runFirstStart(bundle, progress: progress)
        return (bundle, macOS)
    }

    /// The version tag first, then the one that moves with each build: base-27.0.1, then base.
    package static func tags(kind: Kind, macOS: MacOS, xcode: String?) -> [String] {
        let versionTag = [kind.rawValue, macOS.version, xcode].compactMap { $0 }.joined(separator: "-")
        return [versionTag, kind.rawValue]
    }

    @MainActor
    private static func buildVanilla(ipsw: String, progress: @escaping ProgressHandler) async throws -> (
        VMBundle, MacOS
    ) {
        let bundle = try await MacInstaller.createVM(
            name: Kind.vanilla.vmName, source: ipsw, options: CreateOptions(diskSize: GuestOS.macOS.defaultDiskSize),
            provisioning: nil, progress: progress)
        guard let macOS = newestMacOS() else {
            throw HangarError("Hangar's cache has no installed macOS.")
        }
        try record(macOS, in: bundle)
        return (bundle, macOS)
    }

    /// Xcode's first start takes the longest.
    private static let firstStartTimeout: TimeInterval = 90 * 60
    private static let pollInterval = Duration.seconds(15)

    @MainActor
    private static func runFirstStart(_ bundle: VMBundle, progress: @escaping ProgressHandler) async throws {
        try bundle.startInBackground()
        progress(CreationProgress(phase: "Waiting for '\(bundle.name)' to set itself up and shut down…"))
        let deadline = Date().addingTimeInterval(firstStartTimeout)
        while bundle.isRunning {
            guard Date() < deadline else {
                let minutes = Int(firstStartTimeout / 60)
                throw HangarError("'\(bundle.name)' didn't finish in \(minutes) minutes; see \(guestLog) in the VM.")
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
