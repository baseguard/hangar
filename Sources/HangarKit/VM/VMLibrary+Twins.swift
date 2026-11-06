import Foundation
import HangarPackets
import HangarSecrets
import HangarSupport

/// A VM folder copied outside Hangar (in Finder, with cp, or from a backup) keeps the identity of the VM it came
/// from: both would run with one MAC and IP address, and share one set of Keychain secrets.
extension VMLibrary {
    /// The other VM in the library with the same identity as `config`, if there is one.
    package static func twin(of bundle: VMBundle, config: VMConfig) -> VMBundle? {
        for other in all() where other.name != bundle.name {
            guard let otherConfig = try? other.loadConfig() else { continue }
            if sharesIdentity(config, otherConfig) { return other }
        }
        return nil
    }

    /// Why the Keychain items of `bundle` must stay when it is deleted, or nil when no other VM can be using them. A VM
    /// whose config can't be read may be its twin, so it keeps them too.
    static func reasonToKeepKeychainItems(of bundle: VMBundle, config: VMConfig) -> String? {
        for other in all() where other.name != bundle.name {
            guard let otherConfig = try? other.loadConfig() else {
                return "the settings of '\(other.name)' can't be read, so it may be a copy of it."
            }
            if sharesIdentity(config, otherConfig) { return "'\(other.name)', a copy of it, uses them too." }
        }
        return nil
    }

    package static func checkNotTwin(_ bundle: VMBundle, config: VMConfig) throws {
        guard let twin = twin(of: bundle, config: config) else { return }
        throw HangarError(
            "'\(bundle.name)' and '\(twin.name)' are copies of one VM made outside Hangar, so they share its identity, network address and secrets. Start '\(bundle.name)' in the Hangar app to make it a separate VM, or delete one of them; to copy a VM, use `hangar clone`."
        )
    }

    package static func sharesIdentity(_ config: VMConfig, _ other: VMConfig) -> Bool {
        if let machine = config.machineIdentifier, machine == other.machineIdentifier { return true }
        if let mac = MACAddress.normalize(config.network.macAddress),
            mac == MACAddress.normalize(other.network.macAddress)
        {
            return true
        }
        if let vault = config.secrets?.vault, vault == other.secrets?.vault { return true }
        return false
    }

    /// Gives a copy made outside Hangar what `hangar clone` gives its copy, under the name the user picked. Its
    /// Keychain items stay where they are: the twin still uses them.
    package static func separate(_ bundle: VMBundle, as name: String) throws -> VMBundle {
        try validate(name: name, ignoring: name.lowercased() == bundle.name.lowercased() ? bundle : nil)
        let separated = VMBundle(url: HangarPaths.vms.appendingPathComponent(name, isDirectory: true))

        try withStoppedVM(bundle) {
            try copySeed(bundle.cloudInitURL, to: bundle, hostname: name)
            try bundle.updateConfig { $0 = ownIdentity(of: $0) }
            if name != bundle.name {
                try FileManager.default.moveItem(at: bundle.url, to: separated.url)
            }
        }
        return separated
    }

    /// What makes a copy a VM of its own, for a clone and for a copy made outside Hangar alike. Secrets stay with
    /// their VM: the copy has its own Keychain items, or none.
    static func ownIdentity(of config: VMConfig) -> VMConfig {
        var copied = config
        copied.machineIdentifier = VMConfig.newMachineIdentifier(for: config.os)
        copied.network.macAddress = VMConfig.randomMACAddress()
        copied.network.ipAddress = allocateIPAddress()
        copied.provisioning = nil
        copied.autoStart = false
        copied.secrets = nil
        copied.createdAt = Date()
        return copied
    }

    /// A new cloud-init instance makes a Linux guest set up its network and host name again.
    static func copySeed(_ seed: URL, to bundle: VMBundle, hostname: String) throws {
        guard FileManager.default.fileExists(atPath: seed.path) else { return }
        try CloudInit.copySeed(from: seed, to: bundle.cloudInitURL, hostname: hostname)
    }
}
