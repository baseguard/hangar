import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct AutoStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autostart",
        abstract: "Start the VMs that are set to start automatically.",
        discussion: """
            Example:
              hangar set deb --autostart on
                  Mark deb; Hangar.app starts it whenever it opens.
              hangar autostart
                  Start the marked VMs now, in the background.
            """
    )

    func run() throws {
        let bundles = VMLibrary.stoppedAutoStartVMs()
        guard !bundles.isEmpty else {
            print("No stopped VM is set to start automatically.")
            return
        }

        var failed: [String] = []

        for bundle in bundles {
            do {
                let pid = try bundle.startInBackground()
                print("Started '\(bundle.name)' (pid \(pid)).")
            } catch {
                printError(error.localizedDescription)
                failed.append(bundle.name)
            }
        }

        guard failed.isEmpty else { throw HangarError("Could not start \(failed.joined(separator: ", ")).") }
    }
}
