import Darwin
import Foundation
import HangarSupport

package enum ImageBuilder {
    package enum Kind: String, CaseIterable, Sendable {
        case vanilla, base, xcode

        package var vmName: String { "image-\(rawValue)" }
    }

    static let jobLabel = "io.baseguard.hangar.first-start"
    static let folder = ["Library", "Application Support", "Hangar"]
    static let jobPath = ["Library", "LaunchDaemons", "\(jobLabel).plist"]
    package static let guestJob = "/" + jobPath.joined(separator: "/")
    package static let guestFolder = "/" + folder.joined(separator: "/")
    static let appName = "Hangar.app"
    static let guestCommand = guestFolder + "/\(appName)/" + HangarExecutable.bundledPath
    package static let guestSudoers = "/etc/sudoers.d/hangar"
    package static let guestLog = "/var/log/hangar-first-start.log"

    static func job() throws -> Data {
        let job: [String: Any] = [
            "Label": jobLabel,
            "ProgramArguments": [guestCommand, "image", "first-start"],
            "RunAtLoad": true,
            "StandardOutPath": guestLog,
            "StandardErrorPath": guestLog,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    package static func giveAccount(to bundle: VMBundle) throws {
        let provisioning = MacProvisioning(
            fullName: MacImage.fullName, username: MacImage.user, password: MacImage.password,
            autoLogin: true, remoteLogin: true)
        try provisioning.savePassword()
        try bundle.updateConfig { $0.provisioning = provisioning }
    }

    package struct MacOS: Codable, Sendable {
        package var version: String
        package var build: String
    }

    package static func newestMacOS() -> MacOS? {
        MacTemplates.newest().map { MacOS(version: $0.version, build: $0.buildVersion) }
    }

    package static func record(_ macOS: MacOS, in bundle: VMBundle) throws {
        try JSON.write(macOS, to: bundle.url.appendingPathComponent("image-build.json"))
    }

    package static func macOS(of bundle: VMBundle) throws -> MacOS {
        do {
            return try JSON.read(MacOS.self, from: bundle.url.appendingPathComponent("image-build.json"))
        } catch {
            throw HangarError("'\(bundle.name)' wasn't made by `hangar image build`, so its macOS version is unknown.")
        }
    }

    /// `app` is the whole Hangar.app: the command loads HangarKit from it, and a release's command keeps its Keychain
    /// entitlement only beside the provisioning profile in HangarCLI.app, so macOS refuses to start it alone.
    package static func prepare(disk: URL, app: URL, xcode: URL?) throws {
        guard getuid() == 0 else { throw HangarError("Preparing an image's first start needs root: run it with sudo.") }
        // The job starts this command; without it the VM would wait out the build's deadline.
        guard
            FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(HangarExecutable.bundledPath).path)
        else {
            throw HangarError("\(app.path) has no \(HangarExecutable.bundledPath) to start the image's setup with.")
        }

        let agent = try GuestFiles.data("macos/\(GuestTools.macAgent)")
        try withDataVolume(of: disk, readOnly: false) { volume in
            let root = try GuestDirectory(path: volume.path)
            // Checked before anything is written, so a refused image keeps no job; ditto and chown follow the path, so
            // a link the guest put there must stop here.
            guard try !root.exists(folder + [appName]) else {
                throw HangarError("The image already has \(guestFolder)/\(appName).")
            }
            if xcode != nil, try root.exists(["Applications", "Xcode.app"]) {
                throw HangarError("The image already has an Xcode.app.")
            }

            try root.write(job(), at: jobPath, mode: 0o644)
            try root.write(agent, at: folder + [GuestTools.macAgent], mode: 0o755)
            try copyAsRoot(app, to: volume.appendingPathComponent((folder + [appName]).joined(separator: "/")))
            if let xcode { try copyAsRoot(xcode, to: volume.appendingPathComponent("Applications/Xcode.app")) }
        }
    }

    private static func copyAsRoot(_ app: URL, to destination: URL) throws {
        try ProcessUtil.run("/usr/bin/ditto", [app.path, destination.path])
        try ProcessUtil.run("/usr/sbin/chown", ["-R", "-h", "0:0", destination.path])
    }

    package static func verify(disk: URL) throws -> [String] {
        try withDataVolume(of: disk, readOnly: true) { volume in
            let root = try GuestDirectory(path: volume.path)
            var problems: [String] = []
            for (path, problem) in [
                (jobPath, "the first-start job is still there"),
                (folder, "/Library/Application Support/Hangar is still there"),
                (["private", "var", "log", "hangar-first-start.log"], "the first-start log is still there"),
            ] {
                if try root.exists(path) { problems.append(problem) }
            }

            let sshFolder = volume.appendingPathComponent("private/etc/ssh").path
            let sshFiles = (try? FileManager.default.contentsOfDirectory(atPath: sshFolder)) ?? []
            if sshFiles.contains(where: { $0.hasPrefix("ssh_host_") }) {
                problems.append("/etc/ssh has SSH host keys, which every VM made from the image would share")
            }

            let users =
                (try? FileManager.default.contentsOfDirectory(atPath: volume.appendingPathComponent("Users").path))
                ?? []
            for user in users where user != "Shared" && !user.hasPrefix(".") {
                for leftover in [".ssh", ".zsh_history", ".bash_history", ".netrc", ".gitconfig", ".config/gh"] {
                    let path = ["Users", user] + leftover.split(separator: "/").map(String.init)
                    if try root.exists(path) { problems.append("/Users/\(user)/\(leftover) is in the image") }
                }
            }
            return problems
        }
    }

    static func withDataVolume<T>(of disk: URL, readOnly: Bool, _ body: (URL) throws -> T) throws -> T {
        var template = Array((FileManager.default.temporaryDirectory.path + "/hangar-image.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw HangarError("Could not make a temporary folder.") }

        let mountRoot = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { rmdir(mountRoot.path) }
        let output = try ProcessUtil.run(
            "/usr/bin/hdiutil",
            [
                "attach", "-plist", "-nobrowse", "-noverify", "-noautofsck", "-owners", "on",
                "-mountrandom", mountRoot.path, "-imagekey", "diskimage-class=CRawDiskImage",
            ]
                + (readOnly ? ["-readonly"] : []) + [disk.path])
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = (plist?["system-entities"] as? [[String: Any]] ?? []).compactMap {
            entity -> (device: String, mount: String?)? in
            (entity["dev-entry"] as? String).map { ($0, entity["mount-point"] as? String) }
        }
        guard let whole = entities.map(\.device).min(by: { $0.count < $1.count }) else {
            throw HangarError("hdiutil could not attach \(disk.lastPathComponent).")
        }
        defer { _ = try? ProcessUtil.run("/usr/bin/hdiutil", ["detach", "-force", whole]) }
        let data = try dataVolume(of: whole)
        guard let mount = entities.first(where: { $0.device == "/dev/" + data })?.mount else {
            throw HangarError("The Data volume in \(disk.lastPathComponent) didn't mount.")
        }

        return try body(URL(fileURLWithPath: mount, isDirectory: true))
    }

    static func dataVolume(of device: String) throws -> String {
        let whole = device.replacingOccurrences(of: "/dev/", with: "")
        let output = try ProcessUtil.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        let list = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let volumes = (list?["Containers"] as? [[String: Any]] ?? []).filter { container in
            (container["PhysicalStores"] as? [[String: Any]] ?? []).contains {
                ($0["DeviceIdentifier"] as? String)?.hasPrefix(whole + "s") == true
            }
        }.flatMap { $0["Volumes"] as? [[String: Any]] ?? [] }
        let data = volumes.filter { ($0["Roles"] as? [String])?.contains("Data") == true }
        guard data.count == 1, let identifier = data[0]["DeviceIdentifier"] as? String else {
            throw HangarError("\(device) has no single macOS Data volume.")
        }

        return identifier
    }
}
