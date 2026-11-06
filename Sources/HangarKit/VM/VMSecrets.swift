import Foundation
import HangarSecrets
import HangarSupport

/// Changing a VM's secrets: the value goes to the Keychain, the rule to the VM's config, and a running VM is told.
package enum VMSecrets {
    /// The guest agent sets at most this many variables, and the certificate authority's name constraints grow with
    /// every host.
    static let maximumRules = 32
    static let maximumHosts = 64

    /// The rule as saved, with its placeholder: a rule set again keeps the one the guest already has. Without a value,
    /// a rule set again keeps the value it has.
    @discardableResult
    package static func set(_ rule: SecretRule, value: String?, in bundle: VMBundle) throws -> SecretRule {
        try validate(rule)
        if let value { try SecretRule.validate(value: value) }
        var saved = rule
        try bundle.updateConfig { config in
            try VMLibrary.checkNotTwin(bundle, config: config)
            guard config.network.mode == .managed else {
                throw HangarError(
                    "Secrets need Hangar's managed network, where Hangar sees the VM's traffic: "
                        + "hangar set \(bundle.name) --network managed")
            }
            var settings = config.secrets ?? SecretSettings()
            let old = settings.rules.first { $0.name == rule.name }
            guard old != nil || value != nil else { throw HangarError("Give the value of secret \(rule.name).") }
            if let old { saved.placeholder = old.placeholder }
            settings.rules.removeAll { $0.name == rule.name }
            settings.rules.append(saved)
            try checkLimits(settings)
            if let value { try SecretValues.save(value, for: rule.name, in: settings.vault) }
            config.secrets = settings
        }
        return saved
    }

    package static func remove(_ name: String, from bundle: VMBundle) throws {
        try bundle.updateConfig { config in
            try VMLibrary.checkNotTwin(bundle, config: config)
            guard var settings = config.secrets, settings.rules.contains(where: { $0.name == name }) else {
                throw HangarError("'\(bundle.name)' has no secret named \(name).")
            }
            settings.rules.removeAll { $0.name == name }
            try SecretValues.delete(name, in: settings.vault)
            config.secrets = settings.rules.isEmpty ? nil : settings
            if settings.rules.isEmpty { try SecretAuthority.delete(vault: settings.vault) }
        }
    }

    /// For a VM that is deleted: every item is tried, and one that stays only takes a line in the Keychain.
    static func forget(_ settings: SecretSettings) {
        for rule in settings.rules {
            do {
                try SecretValues.delete(rule.name, in: settings.vault)
            } catch {
                HangarLog.warning("The value of secret \(rule.name) stays in your Keychain: \(error)")
            }
        }
        do {
            try SecretAuthority.delete(vault: settings.vault)
        } catch {
            HangarLog.warning("The certificate authority of a deleted VM stays in your Keychain: \(error)")
        }
    }

    /// False for a VM that isn't running; it picks the change up when it starts.
    package static func applyLive(to bundle: VMBundle) throws -> Bool {
        guard bundle.isRunning else { return false }
        _ = try ControlClient.send(.reloadSecrets, to: bundle)
        return true
    }

    private static func validate(_ rule: SecretRule) throws {
        try SecretRule.validate(name: rule.name)
        guard !rule.hosts.isEmpty else { throw HangarError("Give the hosts the secret is for: --host api.github.com") }
        for host in rule.hosts {
            try SecretRule.validate(host: host)
        }
        if let header = rule.header { try SecretRule.validate(header: header) }
    }

    private static func checkLimits(_ settings: SecretSettings) throws {
        guard settings.rules.count <= maximumRules else {
            throw HangarError("A VM can have up to \(maximumRules) secrets.")
        }
        guard settings.hosts.count <= maximumHosts else {
            throw HangarError("A VM's secrets can name up to \(maximumHosts) hosts in all.")
        }
    }
}
