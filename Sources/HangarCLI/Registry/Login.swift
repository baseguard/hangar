import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Login: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to a registry, for export and create --image.",
        discussion: """
            Examples:
              hangar login ghcr.io --username octocat
                  Asks for a token and keeps it in your Keychain.
              echo "$TOKEN" | hangar login ghcr.io -u octocat --password-stdin
                  The same, for scripts and CI.
            """
    )

    @Argument(help: ArgumentHelp("The registry, like ghcr.io.", valueName: "registry")) var registry: String
    @Option(name: .shortAndLong, help: ArgumentHelp("Your user name there.", valueName: "name")) var username: String
    @Flag(help: "Read the token from standard input.") var passwordStdin = false
    @Flag(help: "Reach the registry over plain HTTP instead of HTTPS.") var insecure = false

    func run() throws {
        let token = try passwordStdin ? readSecretFromStandardInput() : askForToken()
        let credentials = RegistryCredentials(user: username, token: token)
        try credentials.validate(for: registry)
        if insecure { HangarLog.warning(ImageReference.plainHTTPWarning) }
        runMain { [registry, username, insecure] in
            try await credentials.check(at: registry, plainHTTP: insecure)
            try credentials.save(for: registry)
            print("Signed in to \(registry) as \(username). The token is in your Keychain.")
        }
    }

    private func askForToken() throws -> String {
        guard let token = askHidden("Token for \(username) at \(registry): ") else {
            throw HangarError("Could not read the token.")
        }
        return token
    }
}
