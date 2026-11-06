import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

@main
struct Hangar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hangar",
        abstract: "Create and run macOS, Linux and Windows VMs with Apple's Virtualization framework.",
        discussion: """
            Examples:
              hangar create mac --os macos --image base
                  A macOS VM with Homebrew (user admin, password admin).
              hangar run mac --background
                  Start it in the background.
              ssh admin@$(hangar ip mac --wait 60)
                  Sign in to it over SSH.
              hangar traffic mac --follow
                  Watch where its network traffic goes.
            """,
        version: HangarVersion.current,
        subcommands: [NetworkDaemonCommand.self, ImageCommand.self],
        groupedSubcommands: [
            CommandGroup(
                name: "Library",
                subcommands: [
                    List.self, Create.self, TemplateCommand.self, Info.self, Clone.self, Rename.self, Delete.self,
                    Prune.self,
                    IPSW.self,
                ]),
            CommandGroup(name: "Registry", subcommands: [Export.self, Login.self, Logout.self]),
            CommandGroup(
                name: "Running",
                subcommands: [
                    Run.self, Stop.self, Pause.self, Resume.self, AutoStart.self, Stats.self, Logs.self,
                ]),
            CommandGroup(
                name: "Connecting", subcommands: [IP.self, Exec.self, Copy.self, Setup.self, MCPCommand.self]),
            CommandGroup(
                name: "Settings", subcommands: [SetCommand.self, Share.self, Secret.self, SnapshotCommand.self]),
            CommandGroup(name: "Network", subcommands: [Traffic.self, Policy.self, NetworkCommand.self]),
        ]
    )

    /// macOS refuses the no-SIGPIPE flag on a socket whose peer has already closed it, such as a guest that drops its
    /// end at once, and the next write would end the process; every writer handles the failed write instead.
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        main(nil)
    }
}
