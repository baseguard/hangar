import Foundation
internal import HangarSupport

/// One secret of a VM: the guest sees `placeholder` in the environment variable `name`, and the secrets proxy puts the
/// real value, kept in the Mac's Keychain, in its place on requests to `hosts`.
package struct SecretRule: Codable, Hashable, Sendable {
    /// Where a header's format takes the value.
    package static let valueMarker = "%s"

    /// A header the proxy sets on every request to the hosts, with the value where the format has `%s`.
    package struct Header: Codable, Hashable, Sendable {
        package var name: String
        package var format: String

        package init(name: String, format: String) {
            self.name = name
            self.format = format
        }
    }

    package var name: String
    package var hosts: [String]
    package var placeholder: String
    package var header: Header?

    package init(
        name: String, hosts: [String], placeholder: String = SecretRule.newPlaceholder(), header: Header? = nil
    ) {
        self.name = name
        self.hosts = hosts.map { $0.lowercased() }
        self.placeholder = placeholder
        self.header = header
    }

    /// A config.json edited by hand gets its hosts lowercased too, so a rule's hosts are always lowercase.
    package init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try fields.decode(String.self, forKey: .name),
            hosts: try fields.decode([String].self, forKey: .hosts),
            placeholder: try fields.decode(String.self, forKey: .placeholder),
            header: try fields.decodeIfPresent(Header.self, forKey: .header))
    }

    /// Letters and digits only, so it can stand in a header, a URL or JSON without escaping.
    package static func newPlaceholder() -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return "hangar" + String((0..<32).map { _ in letters.randomElement() ?? "x" })
    }

    /// The rule `hangar secret set` saves for a secret the VM may have, like a template's: the hosts and header given
    /// replace the old ones, and those left out are kept.
    package static func toSave(
        name: String, hosts: [String], header: Header?, replacing existing: SecretRule?
    ) -> SecretRule {
        guard let existing else { return SecretRule(name: name, hosts: hosts, header: header) }

        return SecretRule(
            name: name, hosts: hosts.isEmpty ? existing.hosts : hosts, placeholder: existing.placeholder,
            header: header ?? existing.header)
    }

    package func applies(to host: String) -> Bool {
        hosts.contains(host.lowercased())
    }

    /// The guest agent accepts the same names and nothing else.
    package static func validate(name: String) throws {
        guard name.wholeMatch(of: /[A-Z_][A-Z0-9_]{0,63}/) != nil else {
            throw HangarError(
                "'\(name)' can't be a secret's name: use capital letters, digits and '_', like GITHUB_TOKEN.")
        }
        guard !isGuestSystemVariable(name) else {
            throw HangarError(
                "'\(name)' can't be a secret's name: the VM's shells and programs rely on it. Give the secret a name of its own, like GITHUB_TOKEN."
            )
        }
    }

    /// The guest sets a secret's variable for every user on every start, so one of these could break every shell
    /// in the VM or make other users' programs load code from elsewhere. The guest agent refuses the same names.
    private static let guestSystemVariables: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "ZDOTDIR", "TMPDIR", "TEMP", "TMP",
        "COMSPEC", "SYSTEMROOT", "WINDIR", "PATHEXT", "NODE_OPTIONS", "PYTHONPATH", "PYTHONHOME", "PERL5OPT", "RUBYOPT",
        "JAVA_TOOL_OPTIONS", "NODE_EXTRA_CA_CERTS", "PERL5LIB", "PERLLIB", "RUBYLIB", "NODE_PATH", "CLASSPATH",
        "PYTHONSTARTUP", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "GCONV_PATH",
    ]
    private static let guestSystemPrefixes = ["LD_", "DYLD_"]

    private static func isGuestSystemVariable(_ name: String) -> Bool {
        guestSystemVariables.contains(name) || guestSystemPrefixes.contains { name.hasPrefix($0) }
    }

    package static func validate(host: String) throws {
        let isHostName = host.wholeMatch(of: /[A-Za-z0-9]([A-Za-z0-9-]{0,62}\.)+[A-Za-z]{2,63}/) != nil
        guard isHostName, host.count <= 253 else {
            throw HangarError("'\(host)' isn't a host name, like api.github.com.")
        }
    }

    /// A header's format holds the value once: "Bearer %s".
    package static func validate(header: Header) throws {
        guard header.name.wholeMatch(of: /[A-Za-z0-9-]{1,64}/) != nil else {
            throw HangarError("'\(header.name)' can't be a header's name.")
        }
        guard header.format.components(separatedBy: valueMarker).count == 2,
            !header.format.contains(where: \.isNewline)
        else {
            throw HangarError("The header's value must have %s once, where the secret goes: \"Bearer %s\".")
        }
    }

    /// A value with a line break could add headers of its own. Answers are searched for the value to mask it, so a
    /// short one would mask unrelated text too.
    package static let shortestValue = 8
    package static let longestValue = 8192

    package static func validate(value: String) throws {
        guard (shortestValue...longestValue).contains(value.utf8.count) else {
            throw HangarError("A secret must be \(shortestValue) to \(longestValue) bytes long.")
        }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw HangarError("A secret can't contain line breaks or other control characters.")
        }
    }
}

/// A VM's secrets. `vault` names its Keychain items; it is new for every VM, so a clone or an imported image finds no
/// secrets and no certificate authority of another VM.
package struct SecretSettings: Codable, Hashable, Sendable {
    package var vault: String
    package var rules: [SecretRule]

    package init(vault: String = UUID().uuidString, rules: [SecretRule] = []) {
        self.vault = vault
        self.rules = rules
    }

    package var hosts: Set<String> {
        Set(rules.flatMap(\.hosts))
    }
}
