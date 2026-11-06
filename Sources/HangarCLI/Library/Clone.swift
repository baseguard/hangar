import ArgumentParser
import Foundation
import HangarKit

struct Clone: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy a VM or one of its snapshots.",
        discussion: """
            Examples:
              hangar clone deb deb2
                  A copy of the stopped VM deb.
              hangar clone deb deb2 --snapshot clean
                  A copy of deb's snapshot clean; deb can keep running.

            The copy is instant and only takes space as it changes. It gets its own MAC address, IP address and machine \
            identity, and starts up fresh.
            """
    )

    @Argument(help: ArgumentHelp("The VM to copy.", valueName: "vm")) var source: String
    @Argument(help: ArgumentHelp("Name of the copy.", valueName: "name")) var name: String
    @Option(help: ArgumentHelp("Copy this snapshot instead of the VM's current disk.", valueName: "snapshot"))
    var snapshot: String?

    func run() throws {
        let bundle = try VMLibrary.bundle(named: source)
        let selected = try snapshot.map { try bundle.snapshot(named: $0) }
        try VMLibrary.validate(name: name)
        runMain { [self] in
            if let selected {
                let clone = try await VMLibrary.clone(selected, as: name)
                print("Cloned '\(source)' at '\(selected.name)' to '\(clone.name)'.")
            } else {
                let clone = try await VMLibrary.clone(bundle, as: name)
                print("Cloned '\(source)' to '\(clone.name)'.")
            }
        }
    }
}
