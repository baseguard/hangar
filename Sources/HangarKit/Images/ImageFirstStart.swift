import Darwin
import Foundation
import HangarSupport

/// What a new image VM does on its first start, as root from its LaunchDaemon: makes the console user an
/// administrator without a password, keeps the VM awake, installs the agent and the tools, and leaves nothing of
/// the build behind. `say` gets each step's line for the job's log.
package enum ImageFirstStart {
    private struct ConsoleUser {
        let name: String
        let uid: uid_t
    }

    package static func run(say: @escaping (String) -> Void) throws {
        guard getuid() == 0 else { throw HangarError("first-start runs as root from its LaunchDaemon.") }

        let signals = [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                unlink(ImageBuilder.guestJob)
                Darwin.exit(1)
            }
            source.activate()
            return source
        }
        defer {
            unlink(ImageBuilder.guestJob)
            withExtendedLifetime(signals) {}
        }
        say("Started")

        do {
            try setUp(say: say)
        } catch {
            say("Failed: \(error.localizedDescription)")
            unlink(ImageBuilder.guestJob)
            try? ProcessUtil.runShowingOutput("/sbin/shutdown", ["-h", "now"])
            throw error
        }
    }

    private static func setUp(say: (String) -> Void) throws {
        let user = try waitForConsoleUser()
        say("Setting up for \(user.name) (\(user.uid))")
        try allowSudoWithoutPassword(for: user)
        try keepAwake(for: user)
        say("sudo without a password, no sleep or screen lock")

        if FileManager.default.fileExists(atPath: "/Applications/Xcode.app") {
            try ProcessUtil.runShowingOutput(
                "/usr/bin/xcode-select", ["-s", "/Applications/Xcode.app/Contents/Developer"])
            try ProcessUtil.runShowingOutput("/usr/bin/xcodebuild", ["-license", "accept"])
            try ProcessUtil.runShowingOutput("/usr/bin/xcodebuild", ["-runFirstLaunch"])
            try ProcessUtil.runShowingOutput("/usr/bin/xcodebuild", ["-downloadPlatform", "iOS"])
            say("Xcode and the iOS platform set up")
        }

        try installAgent(for: user)
        say("Agent, Command Line Tools and Homebrew installed")
        try removeSSHHostKeys()
        say("SSH host keys removed; each VM makes its own")
        try setTimeZoneToGMT()
        say("Time zone set to GMT")
        try eraseSystemLogs()
        say("System logs erased")

        try FileManager.default.removeItem(atPath: ImageBuilder.guestFolder)
        unlink(ImageBuilder.guestJob)
        say("Finished")
        unlink(ImageBuilder.guestLog)
        try? ProcessUtil.runShowingOutput("/sbin/shutdown", ["-h", "now"])
    }

    private static func waitForConsoleUser() throws -> ConsoleUser {
        while true {
            let owner =
                (try? FileManager.default.attributesOfItem(atPath: "/dev/console"))?[.ownerAccountName] as? String
            if let owner, !["root", "_mbsetupuser", "loginwindow"].contains(owner), let entry = getpwnam(owner) {
                guard entry.pointee.pw_uid >= 500 else { throw HangarError("\(owner) is not a local user account.") }
                try VMConfig.validate(userName: owner)
                return ConsoleUser(name: owner, uid: entry.pointee.pw_uid)
            }
            sleep(5)
        }
    }

    private static func allowSudoWithoutPassword(for user: ConsoleUser) throws {
        let fd = open(ImageBuilder.guestSudoers, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o440)
        guard fd >= 0 else {
            throw HangarError(errno: errno, "Could not create \(ImageBuilder.guestSudoers)")
        }
        defer { close(fd) }
        let rule = Data("\(user.name) ALL=(ALL) NOPASSWD: ALL\n".utf8)
        let written = rule.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == rule.count, fchown(fd, 0, 0) == 0, fchmod(fd, 0o440) == 0 else {
            throw HangarError("Could not write \(ImageBuilder.guestSudoers).")
        }
    }

    private static func keepAwake(for user: ConsoleUser) throws {
        try ProcessUtil.runShowingOutput("/usr/bin/pmset", ["-a", "sleep", "0", "displaysleep", "0", "disksleep", "0"])
        try ProcessUtil.runShowingOutput(
            "/usr/bin/defaults",
            ["write", "/Library/Preferences/com.apple.screensaver", "loginWindowIdleTime", "-int", "0"])
        try ProcessUtil.runShowingOutput(
            "/bin/launchctl",
            [
                // In the user's session, where their preferences daemon is; from outside it the write fails with
                // "Could not write domain".
                "asuser", String(user.uid), "/usr/bin/sudo", "-u", user.name, "-H", "/usr/bin/defaults",
                "-currentHost", "write", "com.apple.screensaver", "idleTime", "-int", "0",
            ])

        if user.name == MacImage.user {
            try ProcessUtil.runShowingOutput(
                "/bin/launchctl",
                [
                    "asuser", String(user.uid), "/usr/bin/sudo", "-u", user.name, "/usr/sbin/sysadminctl",
                    "-screenLock", "off", "-password", MacImage.password,
                ])
        }
    }

    // Provisioning sets no time zone, so the image would keep the one it was built in; use GMT.
    private static func setTimeZoneToGMT() throws {
        try ProcessUtil.runShowingOutput("/usr/sbin/systemsetup", ["-settimezone", "GMT"])
    }

    // The guest's log can hold names it saw on the builder's network, such as the Mac's Bonjour name.
    private static func eraseSystemLogs() throws {
        try ProcessUtil.runShowingOutput("/usr/bin/log", ["erase", "--all"])
    }

    // Keys left in the image would be the same in every VM made from it. macOS's sshd-keygen-wrapper makes new ones
    // on a VM's first SSH connection.
    private static func removeSSHHostKeys() throws {
        let folder = "/etc/ssh"
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) where name.hasPrefix("ssh_host_") {
            try FileManager.default.removeItem(atPath: "\(folder)/\(name)")
        }
    }

    private static func installAgent(for user: ConsoleUser) throws {
        let agent = ImageBuilder.guestFolder + "/" + GuestTools.macAgent
        try ProcessUtil.runShowingOutput(
            "/bin/launchctl", ["asuser", String(user.uid), "/usr/bin/sudo", "-u", user.name, "-H", agent, "install"])
    }

}
