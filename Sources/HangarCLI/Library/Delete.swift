import ArgumentParser
import Foundation
import HangarKit

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete stopped VMs with their disks and snapshots.",
        discussion: """
            Example:
              hangar delete deb deb2
            """,
        aliases: ["rm"]
    )

    @Argument(help: ArgumentHelp("The VMs.", valueName: "vm")) var names: [String]

    func run() throws {
        for name in names {
            try VMLibrary.delete(try VMLibrary.bundle(named: name))
            print("Deleted '\(name)'.")
        }
    }
}
