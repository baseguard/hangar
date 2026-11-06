import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update Hangar's agent in a running VM, or show how to install it.",
        discussion: """
            Examples:
              hangar setup deb
                  Updates the agent that answers in deb, or shows the steps.
              hangar setup deb --password-stdin < password.txt
                  The same, with the guest password the update may need.

            The agent shares the clipboard, reports the VM's real memory use and puts dropped files in place. New VMs \
            get it by themselves. An agent that answers is updated through hangar exec; on Linux and macOS that may \
            need the guest password, and Windows asks you to click Yes in the VM. Otherwise this shows the steps to \
            install it: on macOS it asks for your password once, since its system part runs as root, and it installs \
            the Command Line Tools and Homebrew if they're missing.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @Flag(help: "Read the guest password for the update from standard input.")
    var passwordStdin = false

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        let config = try bundle.loadConfig()
        guard bundle.isRunning else { throw HangarError("Start '\(name)' first.") }

        let installed = Self.agentVersion(of: bundle)
        if let installed, installed >= GuestSetup.agentVersion {
            print(Self.upToDate(name))
            return
        }
        guard GuestAgentUpdate.canUpdate(from: installed) else {
            try printInstallSteps(for: config.os, in: bundle)
            return
        }
        let password = passwordStdin ? readSecretFromStandardInput() : nil
        runMain { [name] in
            try await Self.update(bundle, os: config.os, password: password)
            print(Self.upToDate(name))
        }
    }

    private static func upToDate(_ vm: String) -> String {
        "Hangar's agent in '\(vm)' is up to date."
    }

    /// Nil when no agent answers.
    private static func agentVersion(of bundle: VMBundle) -> Int? {
        guard case .report(let report)? = try? ControlClient.send(.memory, to: bundle) else { return nil }
        return report?.agentVersion
    }

    private static func update(_ bundle: VMBundle, os: GuestOS, password: String?) async throws {
        do {
            try await GuestAgentUpdate.update(bundle, os: os, password: password) { step in
                printError(step.message(os: os, vm: bundle.name))
            }
        } catch GuestAgentUpdate.Failure.passwordNeeded {
            throw HangarError(
                "Updating the agent in '\(bundle.name)' needs the guest password. Give it on standard input: "
                    + "hangar setup \(bundle.name) --password-stdin")
        } catch GuestAgentUpdate.Failure.wrongPassword {
            throw HangarError("The guest password for '\(bundle.name)' didn't work.")
        }
    }

    private func printInstallSteps(for os: GuestOS, in bundle: VMBundle) throws {
        try GuestTools.prepare()
        // Shares the Tools folder prepared just now; the steps below still help if this fails.
        _ = try? ControlClient.send(.reloadSharedFolders, to: bundle)

        let guide = GuestTools.installGuide(for: os, in: name)
        for (index, step) in guide.steps.enumerated() {
            print("\(index + 1). \(step.text)")
            if let command = step.command { print("\n   \(command)\n") }
        }
        print(guide.summary)
    }
}
