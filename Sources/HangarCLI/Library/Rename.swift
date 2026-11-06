import ArgumentParser
import Foundation
import HangarKit

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rename a stopped VM.",
        discussion: """
            Example:
              hangar rename deb debian
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var name: String
    @Argument(help: ArgumentHelp("Its new name.", valueName: "new-name")) var newName: String

    func run() throws {
        try VMLibrary.rename(try VMLibrary.bundle(named: name), to: newName)
        print("Renamed '\(name)' to '\(newName)'.")
    }
}
