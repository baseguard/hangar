import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut down running VMs.",
        discussion: """
            Examples:
              hangar stop deb
                  Ask deb to shut down, like choosing Shut Down inside it.
              hangar stop --all
                  Shut down every running VM.
              hangar stop deb --force
                  Turn deb off at once, like pulling the plug.
            """
    )

    @Argument(help: ArgumentHelp("The VMs.", valueName: "vm"))
    var names: [String] = []

    @Flag(
        name: .shortAndLong,
        help: "Turn the VM off at once instead of asking it to shut down. Unsaved work in it is lost.")
    var force = false

    @Flag(help: "Shut down every running VM.")
    var all = false

    @Option(
        name: .customLong("timeout"),
        help: ArgumentHelp(
            "Default: \(Stop.defaultTimeout). How long to wait for a VM to shut down before turning it off.",
            valueName: "seconds"))
    var timeoutOption: Int?

    private var timeout: Int { timeoutOption ?? Self.defaultTimeout }
    static let defaultTimeout = 60
    /// A forced stop is the hypervisor's own; it takes moments.
    private static let forceTimeout: TimeInterval = 15

    func validate() throws {
        if all, !names.isEmpty { throw ValidationError("Pass VM names or --all, not both.") }
        if !all, names.isEmpty { throw ValidationError("Pass VM names or --all.") }
    }

    func run() throws {
        let bundles = all ? VMLibrary.all().filter(\.isRunning) : try names.map(VMLibrary.bundle(named:))
        var failed: [String] = []
        for bundle in bundles {
            do {
                try stop(bundle)
            } catch {
                printError(error.localizedDescription)
                failed.append(bundle.name)
            }
        }
        guard failed.isEmpty else { throw HangarError("Could not stop \(failed.joined(separator: ", ")).") }
    }

    /// Asks the guest to shut down and waits; a guest that doesn't is turned off.
    private func stop(_ bundle: VMBundle) throws {
        guard let info = bundle.runInfo else {
            print("'\(bundle.name)' is not running.")
            return
        }

        if !force, try askToShutDown(bundle) {
            print("Stopped '\(bundle.name)'.")
            return
        }
        try forceOff(bundle, info)
        print("Stopped '\(bundle.name)' (forced).")
    }

    /// True once the guest has shut down within the timeout.
    private func askToShutDown(_ bundle: VMBundle) throws -> Bool {
        do {
            _ = try ControlClient.send(.stop, to: bundle)
        } catch {
            throw HangarError("\(error.localizedDescription) Use --force to power it off.")
        }

        print("Asked '\(bundle.name)' to shut down…")
        if ProcessUtil.wait(timeout: TimeInterval(timeout), until: { !bundle.isRunning }) { return true }

        print("'\(bundle.name)' did not shut down within \(timeout)s; forcing it off.")
        if (try? bundle.loadConfig())?.os == .macOS {
            print(
                "macOS waits for an answer while Setup Assistant is on screen. Click Continue once in its window (hangar run \(bundle.name)); after that it shuts down on its own."
            )
        }
        return false
    }

    /// Through the VM's control socket, or, for a VM this command line started that no longer answers, its process.
    private func forceOff(_ bundle: VMBundle, _ info: RunInfo) throws {
        do {
            _ = try ControlClient.send(.forceStop, to: bundle)
        } catch {
            guard info.host == .cli, info.pid > 0, bundle.runInfo?.pid == info.pid else { throw error }
            kill(info.pid, SIGKILL)
        }

        guard ProcessUtil.wait(timeout: Self.forceTimeout, until: { !bundle.isRunning }) else {
            throw HangarError("Could not stop '\(bundle.name)'.")
        }
    }
}
