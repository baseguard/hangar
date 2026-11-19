import Darwin
import Foundation
import HangarDisks
import HangarSupport

/// Updating Hangar.app to a release. The release's disk image is downloaded, checked against GitHub's digest and,
/// before it is attached, checked to be Baseguard's (`AppSignature`); the app in it is copied next to the installed
/// one, checked the same way, and takes the installed one's place when Hangar quits. VMs started from the command
/// line keep running the old build.
package enum AppUpdate {
    private static let appName = "Hangar.app"
    /// Hidden next to the installed app, so it is on the same volume and the swap is a rename.
    private static let stagedPrefix = ".Hangar-update-"

    static var folder: URL { HangarPaths.cache.appendingPathComponent("updates", isDirectory: true) }

    /// The release's app, ready next to `installed` to take its place.
    @concurrent
    package static func prepare(
        _ release: AppRelease, replacing installed: URL, progress: @escaping ProgressHandler
    ) async throws -> URL {
        try checkCanReplace(installed)
        let diskImage = try await download(release, progress: progress)
        progress(CreationProgress(phase: "Checking Hangar \(release.version)"))
        try checkDiskImage(diskImage)
        let staged = try copyApp(from: diskImage, nextTo: installed)
        do {
            try check(staged, is: release.version)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try? FileManager.default.removeItem(at: diskImage)
        return staged
    }

    /// Swaps the two apps in one step, so a failure leaves a whole Hangar in place, then removes the old one.
    package static func install(_ staged: URL, replacing installed: URL) throws {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw HangarError(errno: errno, "Could not put Hangar's update in place of \(installed.path)")
        }
        do {
            try FileManager.default.removeItem(at: staged)
        } catch {
            HangarLog.warning(
                "Hangar is updated; the old version stays at \(staged.path): \(error.localizedDescription)")
        }
    }

    /// Opens `app` once this process has ended, with the same Hangar home.
    package static func relaunch(_ app: URL) throws {
        let waitThenOpen = [
            #"pid=$1; shift"#, #"while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done"#,
            #"exec /usr/bin/open "$@""#,
        ].joined(separator: "; ")
        let arguments = ["-c", waitThenOpen, "hangar-relaunch", String(getpid())] + openArguments(for: app)
        try HangarPaths.createDirectory(folder)
        try ProcessUtil.spawnDetached(
            URL(fileURLWithPath: "/bin/sh"), arguments: arguments, logURL: folder.appendingPathComponent("relaunch.log")
        )
    }

    /// An update prepared but never installed, as when Hangar was force-quit, and downloads it left.
    package static func removeLeftovers(nextTo installed: URL) {
        let parent = installed.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(stagedPrefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func checkCanReplace(_ installed: URL) throws {
        guard installed.lastPathComponent == appName, !installed.path.contains("/AppTranslocation/") else {
            throw HangarError("Move Hangar to your Applications folder, open it from there, and update it then.")
        }
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
            FileManager.default.isWritableFile(atPath: installed.path)
        else {
            throw HangarError(
                "Hangar can't replace itself in \(parent.path), where you can't change files. Download the new version and drag it to that folder."
            )
        }
    }

    private static func download(_ release: AppRelease, progress: @escaping ProgressHandler) async throws -> URL {
        let file = folder.appendingPathComponent("Hangar-\(release.version).dmg")
        return try await Downloader.cached(
            release.diskImage, as: file, digest: release.diskImageDigest,
            phase: "Downloading Hangar \(release.version)",
            progress: progress)
    }

    /// A download that isn't Baseguard's goes, so the next try downloads the image again rather than reusing it.
    private static func checkDiskImage(_ diskImage: URL) throws {
        do {
            try AppSignature.checkDiskImage(diskImage)
        } catch {
            try? FileManager.default.removeItem(at: diskImage)
            throw error
        }
    }

    /// `ditto` keeps the app's signature, extended attributes and links as they are.
    private static func copyApp(from diskImage: URL, nextTo installed: URL) throws -> URL {
        let mountRoot = try HangarPaths.createDirectory(folder.appendingPathComponent("mount", isDirectory: true))
        let image = try DiskImage.attach(diskImage, readOnly: true, mountRoot: mountRoot)
        // rmdir, not a recursive remove: a volume that failed to detach keeps its files.
        defer {
            image.detach()
            rmdir(mountRoot.path)
        }
        guard let app = image.mountPoints.map({ $0.appendingPathComponent(appName) }).first(where: isDirectory)
        else {
            throw HangarError("The downloaded disk image has no \(appName).")
        }

        let staged = installed.deletingLastPathComponent()
            .appendingPathComponent(stagedPrefix + UUID().uuidString.prefix(8) + ".app")
        do {
            try ProcessUtil.run("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    private static func check(_ app: URL, is version: AppVersion) throws {
        try AppSignature.checkApp(app)
        let shown = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard shown.flatMap(AppVersion.init) == version else {
            throw HangarError("The downloaded Hangar is version \(shown ?? "unknown"), not \(version).")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A Hangar started with its own home keeps it.
    private static func openArguments(for app: URL) -> [String] {
        guard let home = ProcessInfo.processInfo.environment["HANGAR_HOME"], !home.isEmpty else { return [app.path] }
        return ["--env", "HANGAR_HOME=\(home)", app.path]
    }
}
