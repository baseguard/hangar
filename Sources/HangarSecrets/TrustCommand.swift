import Foundation

/// The line that tells the guest agent what to trust and which variables to set: the VM's certificate authority, as
/// DER in hex or `-` for none, then each secret's variable with its placeholder. It is always the whole state, so the
/// agent removes what isn't in it. `hangar_host_commands` in the guest agent reads it.
package enum TrustCommand {
    package static func line(authority: [UInt8]?, rules: [SecretRule]) -> String {
        let certificate = authority.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"
        let variables = rules.map { "\($0.name)=\($0.placeholder)" }
        return (["trust", certificate] + variables).joined(separator: " ") + "\n"
    }
}

extension SecretsProxyServer.Secrets {
    /// The rules that have a value, with their values from the Keychain and the authority for the hosts; `nil` for a
    /// VM without any.
    package static func load(_ settings: SecretSettings?) throws -> Self? {
        guard let settings else { return nil }
        let values = try SecretValues.read(settings)
        let rules = settings.rules.filter { values[$0.name] != nil }
        guard !rules.isEmpty else { return nil }

        let authority = try SecretAuthority.load(vault: settings.vault, hosts: settings.hosts)
        return Self(rules: rules, values: values, authority: authority)
    }

    package var hosts: Set<String> {
        Set(rules.flatMap(\.hosts))
    }

    package var trustLine: String {
        TrustCommand.line(authority: authority.certificateDER, rules: rules)
    }
}
