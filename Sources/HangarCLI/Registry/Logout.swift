import ArgumentParser
import Foundation
import HangarKit

struct Logout: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forget the sign-in for a registry.",
        discussion: """
            Example:
              hangar logout ghcr.io
            """
    )

    @Argument(help: ArgumentHelp("The registry, like ghcr.io.", valueName: "registry")) var registry: String

    func run() throws {
        try RegistryCredentials.remove(for: registry)
        print("Signed out of \(registry).")
    }
}
