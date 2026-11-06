import Foundation
internal import HangarSupport

/// The secrets' values, in the Mac's Keychain only: never in a VM's files, a log or a command line.
package enum SecretValues {
    package static func save(_ value: String, for rule: String, in vault: String) throws {
        try SecretRule.validate(value: value)
        try Keychain.save(value, for: account(rule, vault), label: "Hangar secret \(rule)")
    }

    package static func delete(_ rule: String, in vault: String) throws {
        try Keychain.delete(account(rule, vault))
    }

    /// Every value a VM's rules have, read once when the proxy starts or the rules change. A rule without one, like a
    /// template's before its value is given, is left out.
    package static func read(_ settings: SecretSettings) throws -> [String: String] {
        var values: [String: String] = [:]
        for rule in settings.rules {
            do {
                let value = try Keychain.read(account(rule.name, settings.vault))
                values[rule.name] = try checked(value, of: rule.name)
            } catch is Keychain.Missing {
                continue
            }
        }
        return values
    }

    /// Checked again on the way out: a value edited in the Keychain to hold a line break would otherwise end up in a
    /// request header.
    static func checked(_ value: String, of rule: String) throws -> String {
        do {
            try SecretRule.validate(value: value)
        } catch {
            throw HangarError(
                "The value of secret \(rule) in your Keychain isn't one Hangar saved (\(error)). Set it again.")
        }
        return value
    }

    /// The names of the rules that have a value, found without reading any, so nobody is asked to allow it.
    package static func namesWithValues(in settings: SecretSettings) throws -> Set<String> {
        let prefix = account("", settings.vault)
        let saved = try Keychain.accounts(startingWith: prefix).map { String($0.account.dropFirst(prefix.count)) }
        return Set(saved).intersection(settings.rules.map(\.name))
    }

    private static func account(_ rule: String, _ vault: String) -> String {
        "secret.\(vault).\(rule)"
    }
}
