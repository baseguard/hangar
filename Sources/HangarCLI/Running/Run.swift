import AppKit
import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a VM, in a window or in the background.",
        discussion: """
            Examples:
              hangar run deb
                  Open deb in a window. Close the window or press Ctrl+C to shut it down.
              hangar run deb win --background
                  Start deb and win without a window, and return.
              hangar run deb --dir ~/src --dir data:~/datasets:ro
                  Share two folders for this run only, the second read-only.
              hangar run deb --console
                  Use Linux's serial console in this terminal instead of a window.

            Shared folders appear in /Volumes/My Shared Files on macOS, on drive Z: on Windows and in /mnt/hangar on \
            Linux.
            """
    )

    @Argument(help: ArgumentHelp("The VM, or several with --background.", valueName: "vm"))
    var names: [String]

    @OptionGroup(title: "Every VM")
    var common: CommonOptions

    @OptionGroup(title: "macOS")
    var mac: MacOptions

    @OptionGroup(title: "Linux")
    var linux: LinuxOptions

    struct CommonOptions: ParsableArguments {
        @Flag(help: "Start without a window and return; the VM keeps running in the background.")
        var background = false

        @Flag(help: "Run in this terminal without a window, until you press Ctrl+C.")
        var noGraphics = false

        @Option(
            name: .customLong("dir"),
            help: ArgumentHelp(
                "Share a folder for this run only, as path, name:path or name:path:ro. Repeatable.",
                valueName: "folder"))
        var folders: [String] = []

        @Option(help: ArgumentHelp("Attach this ISO for this run only. macOS and Linux.", valueName: "file"))
        var iso: String?
    }

    struct MacOptions: ParsableArguments {
        @Flag(help: "Start up in recovery mode.")
        var recovery = false
    }

    struct LinuxOptions: ParsableArguments {
        @Flag(
            help:
                "Connect the serial console to this terminal instead of opening a window. Stop the VM with `hangar stop` from another terminal."
        )
        var console = false
    }

    private var noGraphics: Bool { common.noGraphics }
    private var folders: [String] { common.folders }
    private var recovery: Bool { mac.recovery }
    private var console: Bool { linux.console }
    private var iso: String? { common.iso }

    func validate() throws {
        if common.background {
            if noGraphics || console || recovery || iso != nil {
                throw ValidationError("--no-graphics, --console, --recovery and --iso don't go with --background.")
            }
            if !folders.isEmpty, names.count != 1 { throw ValidationError("--dir works with one VM at a time.") }
        } else if names.count != 1 {
            throw ValidationError("Give one VM, or several with --background.")
        }
    }

    func run() throws {
        if common.background {
            try startInBackground()
        } else {
            try runHere(names[0])
        }
    }

    private func startInBackground() throws {
        let shared = try folders.map(SharedFolder.parse)
        let arguments = shared.flatMap { ["--dir", "\($0.name):\($0.path)\($0.readOnly ? ":ro" : "")"] }

        for name in names {
            let bundle = try VMLibrary.bundle(named: name)
            guard !bundle.isRunning else {
                print("'\(name)' is already running.")
                continue
            }

            let pid = try bundle.startInBackground(arguments: arguments)
            print("Started '\(name)' (pid \(pid)). Log: \(bundle.logURL.path)")
            for folder in shared {
                print(
                    "Sharing \(folder.path) as '\(folder.name)'\(folder.readOnly ? " (read-only)" : "") for this run.")
            }
        }
    }

    private func runHere(_ name: String) throws {
        let bundle = try VMLibrary.bundle(named: name)
        let os = try bundle.loadConfig().os

        if console, os != .linux {
            throw HangarError("--console works with Linux VMs; macOS and Windows guests have no serial console.")
        }

        if iso != nil { try VMSettings.checkISO(on: os) }
        if recovery, os != .macOS { throw HangarError("--recovery works with macOS VMs.") }
        let isoURL = iso.map { URL(userPath: $0).standardizedFileURL }
        let shared = try folders.map(SharedFolder.parse)
        MainActor.assumeIsolated {
            do {
                let session = try VMSession(
                    bundle: bundle, host: .cli, console: console ? .stdio : .none,
                    bootISO: isoURL, recovery: recovery,
                    headless: noGraphics || console, sharedFolders: shared)
                session.setupEnded = { error in
                    if let error {
                        printError(error.localizedDescription)
                    } else {
                        print("'\(bundle.name)' is set up.")
                    }
                }
                Runner.run(session, mode: console ? .console : (noGraphics ? .headless : .window))
            } catch {
                Hangar.exit(withError: error)
            }
        }
    }
}
