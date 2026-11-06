import Darwin
import Foundation
import HangarDisks
import HangarPackets
import HangarSupport
import Virtualization

package enum VMLibrary {
    package static func all() -> [VMBundle] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: HangarPaths.vms, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
        let withConfig = folders.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
        }

        let bundles = withConfig.map(VMBundle.init(url:))
        return bundles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    package static func stoppedAutoStartVMs() -> [VMBundle] {
        all().filter { !$0.isRunning && (try? $0.loadConfig())?.autoStart == true }
    }

    package static func bundle(named name: String) throws -> VMBundle {
        let bundle = VMBundle(url: HangarPaths.vms.appendingPathComponent(name, isDirectory: true))
        guard isSafeFolderName(name), FileManager.default.fileExists(atPath: bundle.configURL.path) else {
            throw HangarError("No VM named '\(name)'. See `hangar list`.")
        }
        return bundle
    }

    package static func exists(_ name: String, ignoring staging: URL? = nil) -> Bool {
        let taken = name.lowercased()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: HangarPaths.vms.path)) ?? []
        return entries.contains { entry in
            guard entry != staging?.lastPathComponent else { return false }
            let lowered = entry.lowercased()
            return (nameInStaging(lowered) ?? lowered) == taken
        }
    }

    static func isSafeFolderName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !name.isEmpty && name.count <= 40 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    package static let nameRule =
        "Like a host name: up to 40 letters, digits and “-”, starting and ending with a letter or digit."

    package static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?/) != nil
    }

    package static func validate(name: String, ignoring bundle: VMBundle? = nil) throws {
        guard isValidName(name) else {
            throw HangarError("Invalid VM name '\(name)'. \(nameRule)")
        }

        let socketPath = HangarPaths.vms.appendingPathComponent(name).appendingPathComponent("control.sock").path
        guard socketPath.utf8.count < 100 else {
            throw HangarError("VM name '\(name)' is too long for this home directory.")
        }
        guard !exists(name, ignoring: bundle?.url) else {
            throw HangarError("A VM named '\(name)' already exists.")
        }
    }

    /// A VM is created in `.creating-<name>-<8 random characters>` and renamed when it is complete.
    static let stagingPrefix = ".creating-"
    static let deletingPrefix = ".deleting-"

    private static func stagingName(for name: String) -> String {
        "\(stagingPrefix)\(name)-\(UUID().uuidString.prefix(8))"
    }

    /// The VM name in a staging folder's name, or nil for any other folder.
    private static func nameInStaging(_ folder: String) -> String? {
        let tagLength = 1 + 8
        guard folder.hasPrefix(stagingPrefix), folder.count > stagingPrefix.count + tagLength else { return nil }
        return String(folder.dropFirst(stagingPrefix.count).dropLast(tagLength))
    }

    /// The lock sits next to the staging folder and is taken before the folder exists, so another Hangar's
    /// cleanup never sees the folder unlocked.
    static func stagingLock(for staging: URL) -> URL {
        staging.appendingPathExtension("lock")
    }

    package static func create(name: String, body: (VMBundle) async throws -> Void) async throws -> VMBundle {
        try validate(name: name)
        try HangarPaths.createDirectory(HangarPaths.vms)
        removeAbandonedStaging()
        let staging = VMBundle(
            url: HangarPaths.vms.appendingPathComponent(
                stagingName(for: name), isDirectory: true))
        let stagingLockURL = stagingLock(for: staging.url)
        let stagingLock = FileLock(url: stagingLockURL)
        guard try stagingLock.tryLock(.exclusive) else { throw HangarError("Could not lock the folder for '\(name)'.") }
        defer {
            try? FileManager.default.removeItem(at: stagingLockURL)
            stagingLock.unlock()
        }
        try FileManager.default.createDirectory(
            at: staging.url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])

        do {
            try await body(staging)
            // The last step may not have noticed a cancel; a cancelled VM must not appear and start.
            try Task.checkCancellation()
            let final = HangarPaths.vms.appendingPathComponent(name, isDirectory: true)
            guard !exists(name, ignoring: staging.url) else {
                throw HangarError("A VM named '\(name)' already exists.")
            }

            try FileManager.default.moveItem(at: staging.url, to: final)
            return VMBundle(url: final)
        } catch {
            try? FileManager.default.removeItem(at: staging.url)
            throw error
        }
    }

    static var stagingDirectories: [URL] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: HangarPaths.vms, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix(stagingPrefix) && $0.pathExtension != "lock" }
    }

    package static func removeAbandonedStaging() {
        for directory in stagingDirectories where !FileLock.isHeld(stagingLock(for: directory)) {
            DiskImage.detachAll(under: directory)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: stagingLock(for: directory))
        }

        let urls =
            (try? FileManager.default.contentsOfDirectory(at: HangarPaths.vms, includingPropertiesForKeys: nil)) ?? []
        for directory in urls where directory.lastPathComponent.hasPrefix(deletingPrefix) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    package static func delete(_ bundle: VMBundle) throws {
        let trash = HangarPaths.vms.appendingPathComponent(
            "\(deletingPrefix)\(bundle.name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try withStoppedVM(bundle) {
            forgetKeychainItems(of: bundle)
            try FileManager.default.moveItem(at: bundle.url, to: trash)
        }
        try FileManager.default.removeItem(at: trash)
    }

    /// The VM goes either way; an item that stays only takes a line in the Keychain.
    private static func forgetKeychainItems(of bundle: VMBundle) {
        let config: VMConfig
        do {
            config = try bundle.loadConfig()
        } catch {
            HangarLog.warning("The Keychain items of '\(bundle.name)' stay: \(error)")
            return
        }
        if let reason = reasonToKeepKeychainItems(of: bundle, config: config) {
            HangarLog.warning("The Keychain items of '\(bundle.name)' stay: \(reason)")
            return
        }

        config.provisioning?.forgetPassword()
        if let secrets = config.secrets { VMSecrets.forget(secrets) }
    }

    package static func rename(_ bundle: VMBundle, to name: String) throws {
        try validate(name: name, ignoring: name.lowercased() == bundle.name.lowercased() ? bundle : nil)
        try withStoppedVM(bundle) {
            try FileManager.default.moveItem(
                at: bundle.url, to: HangarPaths.vms.appendingPathComponent(name, isDirectory: true))
        }
    }

    package static func withStoppedVM<T>(_ bundle: VMBundle, _ body: () throws -> T) throws -> T {
        let lock = try lockStopped(bundle)
        defer { lock.unlock() }
        return try body()
    }

    static func lockStopped(_ bundle: VMBundle) throws -> FileLock {
        let lock = FileLock(url: bundle.lockURL)
        guard try lock.tryLock(.exclusive, retryingFor: 0.5) else {
            throw VMBundle.stillRunning(bundle.name)
        }
        try lock.write(Data())
        return lock
    }

    @discardableResult
    @concurrent
    package static func clone(_ source: VMBundle, as name: String) async throws -> VMBundle {
        let sourceLock = try lockStopped(source)
        defer { sourceLock.unlock() }
        return try await copy(source.url, config: try source.loadConfig(), as: name)
    }

    @discardableResult
    @concurrent
    package static func clone(_ snapshot: VMSnapshot, as name: String) async throws -> VMBundle {
        let config: VMConfig
        do {
            config = try VMConfig.read(from: snapshot.configURL)
        } catch let error as DecodingError {
            throw HangarError(
                "Could not read the settings of the snapshot '\(snapshot.name)': \(JSON.problem(error)). Restore its config.json or delete the snapshot."
            )
        } catch {
            throw HangarError(
                "Could not read the settings of the snapshot '\(snapshot.name)': \(error.localizedDescription)")
        }
        return try await copy(snapshot.url, config: config, as: name)
    }

    private static func copy(_ directory: URL, config source: VMConfig, as name: String) async throws -> VMBundle {
        try await create(name: name) { staging in
            for file in ["disk.img", "nvram.bin"] {
                let from = directory.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: from.path) else {
                    throw HangarError("Could not copy '\(directory.lastPathComponent)': its \(file) is missing.")
                }
                try cloneFile(from: from, to: staging.url.appendingPathComponent(file))
            }

            let seed = directory.appendingPathComponent(staging.cloudInitURL.lastPathComponent)
            try copySeed(seed, to: staging, hostname: name)
            try staging.saveConfig(ownIdentity(of: source))
        }
    }

    package static func cloneFile(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    package static func allocateIPAddress() -> String? {
        let subnet = SharedNetwork.subnet
        let bundles = all() + stagingDirectories.map(VMBundle.init(url:))
        let configured = bundles.compactMap { try? $0.loadConfig().network.ipAddress }
        var used = Set(configured.compactMap(IPv4Address.init))
        used.formUnion(SharedNetwork.leasedAddresses().values)
        for value in subnet.reservableRange where !subnet.unavailableAddresses.contains(value) {
            if !used.contains(IPv4Address(value)) { return IPv4Address(value).description }
        }
        return nil
    }
}
