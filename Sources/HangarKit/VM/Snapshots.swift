import Darwin
import Foundation
import HangarSupport

extension VMBundle {
    package var snapshotsURL: URL { url.appendingPathComponent("snapshots", isDirectory: true) }

    package var snapshots: [VMSnapshot] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: snapshotsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        return urls.map(VMSnapshot.init(url:)).sorted { $0.createdAt < $1.createdAt }
    }

    package func snapshot(named name: String) throws -> VMSnapshot {
        guard VMLibrary.isSafeFolderName(name), let snapshot = snapshots.first(where: { $0.name == name }) else {
            throw HangarError(
                "'\(self.name)' has no snapshot named '\(name)'. See `hangar snapshot list \(self.name)`.")
        }
        return snapshot
    }
}

package enum Snapshots {
    /// Folders a snapshot is made or exported in, and files a restore replaces, before they are in place.
    static let takingPrefix = ".taking-"
    static let exportingPrefix = ".exporting-"
    static let restoringPrefix = ".restoring-"
    /// The VM's own disk and NVRAM while a restore puts the snapshot's in place.
    static let setAsidePrefix = ".replaced-"
    /// Flushing a large disk of a running VM can take a while.
    static let runningSnapshotTimeout = 900

    package static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// `renaming` may keep its own name in another case, which the Mac's disk sees as the same name.
    package static func validate(name: String, for bundle: VMBundle, renaming: VMSnapshot? = nil) throws {
        guard VMLibrary.isSafeFolderName(name) else {
            throw HangarError("Invalid snapshot name '\(name)'. Use up to 40 letters, digits, '-', '_' or '.'.")
        }
        let isOwnName = name.lowercased() == renaming?.name.lowercased()
        let isTaken = FileManager.default.fileExists(atPath: bundle.snapshotsURL.appendingPathComponent(name).path)
        guard isOwnName || !isTaken else {
            throw HangarError("'\(bundle.name)' already has a snapshot named '\(name)'.")
        }
    }

    @discardableResult
    @concurrent
    package static func take(of bundle: VMBundle, name: String) async throws -> VMSnapshot {
        try validate(name: name, for: bundle)
        let lock = FileLock(url: bundle.lockURL)

        if try lock.tryLock(.exclusive, retryingFor: 0.5) {
            defer { lock.unlock() }
            try lock.write(Data())
            return try await write(bundle, name: name)
        }

        _ = try await ControlClient.sendWaiting(.takeSnapshot(name: name), to: bundle, timeout: runningSnapshotTimeout)

        return try bundle.snapshot(named: name)
    }

    static func write(_ bundle: VMBundle, name: String) async throws -> VMSnapshot {
        try validate(name: name, for: bundle)
        try HangarPaths.createDirectory(bundle.snapshotsURL)
        removeLeftovers(in: bundle)
        let staging = VMSnapshot(url: bundle.snapshotsURL.appendingPathComponent(".taking-\(name)", isDirectory: true))
        try FileManager.default.createDirectory(at: staging.url, withIntermediateDirectories: false)

        do {
            try await copyDisk(of: bundle, to: staging)
            var config = try bundle.loadConfig()
            config.provisioning = nil
            try JSON.write(config, to: staging.configURL)
            let final = bundle.snapshotsURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.moveItem(at: staging.url, to: final)
            return VMSnapshot(url: final)
        } catch {
            try? FileManager.default.removeItem(at: staging.url)
            throw error
        }
    }

    package static func restore(_ snapshot: VMSnapshot, to bundle: VMBundle) throws {
        try VMLibrary.withStoppedVM(bundle) {
            let started = try savedSettings(of: snapshot).firstStartedAt
            removeLeftovers(in: bundle)
            let replacements = try stageFiles(of: snapshot, for: bundle)
            try replaceTogether(replacements)
            try bundle.updateConfig { $0.firstStartedAt = started }
        }
    }

    /// Read before anything changes, so a snapshot whose settings can't be read leaves the VM as it was.
    private static func savedSettings(of snapshot: VMSnapshot) throws -> VMConfig {
        do {
            return try VMConfig.read(from: snapshot.configURL)
        } catch {
            throw HangarError(
                "Could not read the settings saved with snapshot '\(snapshot.name)': \(error.localizedDescription)")
        }
    }

    package static func delete(_ snapshot: VMSnapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    @discardableResult
    package static func rename(_ snapshot: VMSnapshot, of bundle: VMBundle, to name: String) throws -> VMSnapshot {
        try validate(name: name, for: bundle, renaming: snapshot)
        let renamed = bundle.snapshotsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: snapshot.url, to: renamed)
        return VMSnapshot(url: renamed)
    }

    /// A snapshot's file staged next to the VM's file it replaces.
    struct Replacement {
        let staged: URL
        let file: URL

        var setAside: URL { prefixed(file, with: setAsidePrefix) }
    }

    /// The snapshot's disk, and its NVRAM when it has one, cloned next to the VM's own.
    private static func stageFiles(of snapshot: VMSnapshot, for bundle: VMBundle) throws -> [Replacement] {
        var replacements = [try stage(snapshot.diskURL, for: bundle.diskURL)]
        guard FileManager.default.fileExists(atPath: snapshot.nvramURL.path) else { return replacements }
        do {
            replacements.append(try stage(snapshot.nvramURL, for: bundle.nvramURL))
        } catch {
            try? FileManager.default.removeItem(at: replacements[0].staged)
            throw error
        }
        return replacements
    }

    private static func stage(_ source: URL, for file: URL) throws -> Replacement {
        let staged = prefixed(file, with: restoringPrefix)
        try clone(source, to: staged)
        return Replacement(staged: staged, file: file)
    }

    private static func prefixed(_ file: URL, with prefix: String) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(prefix + file.lastPathComponent)
    }

    /// Puts all staged files in place or none, so the VM never has the snapshot's disk with its own NVRAM. The VM's
    /// files are set aside first and put back when anything fails.
    static func replaceTogether(_ replacements: [Replacement]) throws {
        var setAside: [Replacement] = []
        var placed: [Replacement] = []
        do {
            for replacement in replacements where FileManager.default.fileExists(atPath: replacement.file.path) {
                try move(
                    replacement.file, to: replacement.setAside, failure: "Could not set aside \(replacement.file.path)")
                setAside.append(replacement)
            }
            for replacement in replacements {
                try move(
                    replacement.staged, to: replacement.file, failure: "Could not restore \(replacement.file.path)")
                placed.append(replacement)
            }
        } catch {
            undoReplacing(placed: placed, setAside: setAside, of: replacements)
            throw error
        }

        for replacement in setAside {
            try? FileManager.default.removeItem(at: replacement.setAside)
        }
    }

    /// The VM's files go back where they were; staged files that weren't placed, and placed ones that had no file
    /// to replace, are removed.
    private static func undoReplacing(placed: [Replacement], setAside: [Replacement], of replacements: [Replacement]) {
        for replacement in placed where !setAside.contains(where: { $0.file == replacement.file }) {
            try? FileManager.default.removeItem(at: replacement.file)
        }
        for replacement in setAside {
            _ = Darwin.rename(replacement.setAside.path, replacement.file.path)
        }
        for replacement in replacements {
            try? FileManager.default.removeItem(at: replacement.staged)
        }
    }

    @concurrent
    private static func copyDisk(of bundle: VMBundle, to staging: VMSnapshot) async throws {
        try flush(bundle.diskURL)
        try clone(bundle.diskURL, to: staging.diskURL)
        if FileManager.default.fileExists(atPath: bundle.nvramURL.path) {
            try clone(bundle.nvramURL, to: staging.nvramURL)
        }
        if FileManager.default.fileExists(atPath: bundle.cloudInitURL.path) {
            try clone(
                bundle.cloudInitURL, to: staging.url.appendingPathComponent(bundle.cloudInitURL.lastPathComponent))
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            if errno == ENOTSUP {
                throw HangarError(
                    "Could not copy \(source.lastPathComponent): snapshots need Hangar's library on an APFS volume.")
            }
            throw HangarError(errno: errno, "Could not copy \(source.lastPathComponent)")
        }
    }

    private static func removeLeftovers(in bundle: VMBundle) {
        let staged =
            (try? FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil))
            ?? []
        putBackSetAsideFiles(in: bundle)
        let restoring = [bundle.diskURL, bundle.nvramURL].map { prefixed($0, with: restoringPrefix) }

        let exports = staged.filter {
            $0.lastPathComponent.hasPrefix(exportingPrefix) && !FileLock.isHeld(exportLock(in: $0))
        }
        for url in staged.filter({ $0.lastPathComponent.hasPrefix(takingPrefix) }) + exports + restoring {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// After a restore that stopped part way, all or none of the VM's set-aside files go back, so it never keeps the
    /// snapshot's disk with its own NVRAM. A place still empty means the restore didn't finish.
    static func putBackSetAsideFiles(in bundle: VMBundle) {
        let filesSetAside = [bundle.diskURL, bundle.nvramURL].filter {
            FileManager.default.fileExists(atPath: prefixed($0, with: setAsidePrefix).path)
        }
        let isRestoreUnfinished = filesSetAside.contains { !FileManager.default.fileExists(atPath: $0.path) }

        for file in filesSetAside {
            let setAside = prefixed(file, with: setAsidePrefix)
            if isRestoreUnfinished {
                _ = Darwin.rename(setAside.path, file.path)
            } else {
                try? FileManager.default.removeItem(at: setAside)
            }
        }
    }

    static func exportLock(in folder: URL) -> URL {
        folder.appendingPathComponent("export.lock")
    }

    /// Replaces anything at `destination`.
    private static func move(_ source: URL, to destination: URL, failure action: String) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw HangarError(errno: errno, action)
        }
    }

    private static func flush(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(file.path)") }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw HangarError(errno: errno, "Could not flush \(file.path)")
        }
    }
}
