import CryptoKit
import Darwin
import Foundation
import HangarSupport

package enum GuestTools {
    package static let shareName = "Tools"
    /// Where Linux guests mount Hangar's shared folders; the agent and cloud-init use the same place.
    package static let linuxMountPoint = "/mnt/hangar"
    package static let macAgent = "hangar-agent"
    package static let linuxAgent = "hangar-agent"
    package static let windowsAgent = "hangar-agent.exe"

    struct File {
        let name: String
        let data: Data
        let executable: Bool
    }

    static var root: URL { HangarPaths.cache.appendingPathComponent("tools", isDirectory: true) }

    /// How to install the agent by hand in a guest: short steps, one of which may give a command to run there.
    package struct InstallGuide: Equatable, Sendable {
        package struct Step: Equatable, Sendable {
            package let text: String
            package let command: String?

            init(_ text: String, command: String? = nil) {
                self.text = text
                self.command = command
            }
        }

        package let steps: [Step]
        /// What the steps do, in one sentence.
        package let summary: String
    }

    package static func installGuide(for os: GuestOS, in vm: String) -> InstallGuide {
        switch os {
        case .macOS:
            InstallGuide(
                steps: [
                    .init("In “\(vm)”, open Finder › My Shared Files › Tools."),
                    .init("Double-click “\(macAgent)”."),
                    .init("Enter your account's password when it asks for it."),
                ],
                summary:
                    "It puts the agent's system part in place, which runs as root, and installs the Command Line Tools and Homebrew if they're missing."
            )
        case .linux:
            InstallGuide(
                steps: [
                    .init("Open a terminal in “\(vm)”."),
                    .init("Run this command:", command: linuxCommand),
                    .init("Enter your password if sudo asks for it."),
                ],
                summary: "It mounts Hangar's shared folders and installs the agent."
            )
        case .windows:
            InstallGuide(
                steps: [
                    .init("In “\(vm)”, press Windows+R."),
                    .init("Run this command:", command: windowsCommand),
                    .init("Click Yes when Windows asks for permission to make changes."),
                ],
                summary: "It installs Hangar's agent from the shared Tools folder."
            )
        }
    }

    package static var linuxCommand: String {
        let mount = "mount -t virtiofs -o nosuid,nodev \(ConfigurationBuilder.linuxShareTag) \(linuxMountPoint)"
        let install = "\(linuxMountPoint)/\(shareName)/\(linuxAgent) install"
        return "sudo sh -ec 'mkdir -p \(linuxMountPoint); mountpoint -q \(linuxMountPoint) || \(mount); \(install)'"
    }

    package static var windowsCommand: String {
        #"Z:\\#(shareName)\\#(windowsAgent)"#
    }

    package static func folder(for os: GuestOS) throws -> URL {
        try prepare()
        return root.appendingPathComponent(os.rawValue, isDirectory: true)
    }

    /// This build's agent for `os` in the Tools folder, where it is executable, so a copy of it in the guest is too.
    static func agentFile(for os: GuestOS) throws -> URL {
        let name =
            switch os {
            case .macOS: macAgent
            case .linux: linuxAgent
            case .windows: windowsAgent
            }
        return try folder(for: os).appendingPathComponent(name)
    }

    static func files(for os: GuestOS) throws -> [File] {
        switch os {
        case .macOS:
            [File(name: macAgent, data: try GuestFiles.data("macos/\(macAgent)"), executable: true)]
        case .linux:
            [File(name: linuxAgent, data: try GuestFiles.data("linux/\(linuxAgent)"), executable: true)]
        case .windows:
            [File(name: windowsAgent, data: try GuestFiles.data("windows/\(windowsAgent)"), executable: true)]
        }
    }

    /// Puts this build's agents in the share, unless the share's stamp says they are there already.
    package static func prepare() throws {
        try HangarPaths.createDirectory(root)
        let lock = FileLock(url: HangarPaths.cache.appendingPathComponent("tools.lock"))
        try lock.lock(.exclusive)
        defer { lock.unlock() }

        let contents = try GuestOS.allCases.map { ($0, try files(for: $0)) }
        let stamp = stamp(of: contents)
        let stampURL = root.appendingPathComponent(".stamp")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp { return }

        try requireFolder(root)
        for (os, files) in contents {
            try install(files, for: os)
        }
        try Data(stamp.utf8).write(to: stampURL, options: .atomic)
    }

    /// A hash of every file's name, mode and bytes, so a changed agent is written again.
    private static func stamp(of contents: [(GuestOS, [File])]) -> String {
        var hash = SHA256()
        for (os, files) in contents {
            for file in files {
                hash.update(data: Data("\(os.rawValue)/\(file.name)\(file.executable)".utf8))
                hash.update(data: file.data)
            }
        }
        return hash.finalize().hex
    }

    /// The OS's folder holds these files and nothing else.
    private static func install(_ files: [File], for os: GuestOS) throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent(os.rawValue, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try requireFolder(folder)

        let names = Set(files.map(\.name))
        for name in try manager.contentsOfDirectory(atPath: folder.path) where !names.contains(name) {
            try manager.removeItem(at: folder.appendingPathComponent(name))
        }
        for file in files {
            try write(file, into: folder)
        }
    }

    private static func requireFolder(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw HangarError("\(url.path) should be a folder, not a link; delete it and try again.")
        }
    }

    private static func write(_ file: File, into folder: URL) throws {
        let temporary = folder.appendingPathComponent(".\(file.name).\(UUID().uuidString)")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: file.data,
                attributes: [.posixPermissions: file.executable ? 0o755 : 0o644])
        else {
            throw HangarError("Could not write \(temporary.path).")
        }
        guard rename(temporary.path, folder.appendingPathComponent(file.name).path) == 0 else {
            let failure = HangarError(errno: errno, "Could not update \(folder.appendingPathComponent(file.name).path)")
            unlink(temporary.path)
            throw failure
        }
    }
}
