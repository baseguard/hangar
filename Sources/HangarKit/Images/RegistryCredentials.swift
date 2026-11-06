import Foundation
import HangarSupport

package struct RegistryCredentials: Codable, Sendable {
    let user: String
    let token: String

    package init(user: String, token: String) {
        self.user = user
        self.token = token
    }

    package static func forRegistry(_ registry: String) throws -> RegistryCredentials? {
        let saved: String
        do {
            saved = try Keychain.read(keychainAccount(registry))
        } catch is Keychain.Missing {
            return nil
        }
        guard let credentials = try? JSONDecoder().decode(RegistryCredentials.self, from: Data(saved.utf8)) else {
            throw HangarError(
                "Your sign-in for \(registry) in the Keychain is damaged; run `hangar login \(registry)` again.")
        }
        return credentials
    }

    package func validate(for registry: String) throws {
        try Self.checkRegistry(registry)
        guard !user.isEmpty, !token.isEmpty else { throw HangarError("Give a user name and a token.") }
        guard !user.contains(":") else { throw HangarError("A user name can't contain ':'.") }
    }

    /// Throws when the registry refuses this user name and token, before anything is kept.
    package func check(at registry: String, plainHTTP: Bool = false) async throws {
        try await RegistryClient.checkSignIn(self, at: registry, plainHTTP: plainHTTP)
    }

    package func save(for registry: String) throws {
        try validate(for: registry)
        let data = try JSONEncoder().encode(self)
        try Keychain.save(
            String(decoding: data, as: UTF8.self), for: Self.keychainAccount(registry),
            label: "Hangar sign-in for \(registry)",
            comment: user)
    }

    package static func remove(for registry: String) throws {
        try checkRegistry(registry)
        guard try Keychain.delete(keychainAccount(registry)) else {
            throw HangarError("You aren't signed in to \(registry).")
        }
    }

    static func checkRegistry(_ registry: String) throws {
        guard !registry.contains("/"), (try? ImageReference("\(registry)/check:latest"))?.registry == registry else {
            throw HangarError("'\(registry)' is not a registry like ghcr.io.")
        }
    }

    package struct SignIn: Hashable, Sendable {
        package let registry: String
        package let user: String
    }

    package static func signIns() throws -> [SignIn] {
        try Keychain.accounts(startingWith: accountPrefix)
            .map { SignIn(registry: String($0.account.dropFirst(accountPrefix.count)), user: $0.comment ?? "") }
            .sorted { $0.registry < $1.registry }
    }

    var basic: String {
        "Basic " + Data("\(user):\(token)".utf8).base64EncodedString()
    }

    private static let accountPrefix = "registry:"

    private static func keychainAccount(_ registry: String) -> String {
        accountPrefix + registry.lowercased()
    }
}
