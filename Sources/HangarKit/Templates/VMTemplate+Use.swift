import Foundation
import HangarSecrets
import HangarSupport

extension VMTemplate {
    /// How a VM is made from `origin` with the accounts asked for, in the app and on the command line. Hangar's Linux
    /// images get the admin account and Hangar's agent without one, as they do in Quick Start, so the setup commands
    /// can run; a Windows installer needs `windowsAccount`. Without an origin, macOS starts from the vanilla image and
    /// Linux gets an empty disk to install from an ISO later.
    package func source(
        from origin: Origin, linuxAccount: CloudInitAccount?, macAccount: MacProvisioning?,
        windowsAccount: WindowsInstaller.Account?, plainHTTP: Bool = false
    ) throws -> VMSource {
        if let image = origin.image {
            return imageSource(image, linuxAccount: linuxAccount, macAccount: macAccount, plainHTTP: plainHTTP)
        }
        if let cloudImage = origin.cloudImage {
            return .linuxCloudImage(cloudImage, account: linuxAccount ?? .hangarImage, userData: cloudInit)
        }
        if let diskImage = origin.diskImage {
            return .linux(iso: nil, diskImage: diskImage, account: linuxAccount, userData: cloudInit)
        }
        if let ipsw = origin.ipsw { return .macOS(ipsw: ipsw, account: macAccount) }

        switch os {
        case .macOS:
            return .macImage("vanilla", account: macAccount)
        case .linux:
            return .linux(iso: origin.iso, diskImage: nil, account: nil, userData: nil)
        case .windows:
            guard let iso = origin.iso else { throw HangarError("Windows needs an installer ISO or an image.") }
            guard let windowsAccount else { throw HangarError("Windows needs an account for its administrator.") }
            return .windows(iso: iso, account: windowsAccount)
        }
    }

    private func imageSource(
        _ image: String, linuxAccount: CloudInitAccount?, macAccount: MacProvisioning?, plainHTTP: Bool
    ) -> VMSource {
        if VMImage.isImageFile(image) {
            return .imageFile(
                URL(userPath: image), os: os, macAccount: macAccount, linuxAccount: linuxAccount, userData: cloudInit)
        }
        if let macImage = macImage(in: Origin(image: image)) { return .macImage(macImage, account: macAccount) }
        return .registryImage(
            image, os: os, macAccount: macAccount, linuxAccount: linuxAccount, userData: cloudInit,
            plainHTTP: plainHTTP)
    }

    /// One of Hangar's own macOS images (vanilla, base or xcode), which are named without a registry.
    package func macImage(in origin: Origin) -> String? {
        guard os == .macOS, let image = origin.image, !image.contains("/"), !VMImage.isImageFile(image) else {
            return nil
        }
        return image
    }

    /// Sets up a VM just made from this template, with the secret values given by name; a secret without one is
    /// given its value later. Shared folders this Mac won't share are skipped and returned.
    package func setUp(_ bundle: VMBundle, secretValues: [String: String]) throws -> [SkippedFolder] {
        var skipped: [SkippedFolder] = []
        try bundle.updateConfig { config in skipped = try apply(to: &config) }
        for secret in secrets ?? [] {
            guard let value = secretValues[secret.name], !value.isEmpty else { continue }
            try VMSecrets.set(secret.rule(), value: value, in: bundle)
        }
        return skipped
    }
}

extension VMTemplate {
    /// A recipe made of options given on the command line rather than read from a file.
    package init(os: GuestOS, cloudInit: String?) {
        self.os = os
        self.cloudInit = cloudInit
    }
}

extension VMTemplate.Origin {
    /// The same origin made from `path` instead of the file this Mac doesn't have.
    package func replacingLocalFile(with path: String) -> VMTemplate.Origin {
        var origin = self
        if origin.iso != nil { origin.iso = path }
        if origin.diskImage != nil { origin.diskImage = path }
        if origin.ipsw != nil { origin.ipsw = path }
        if origin.image != nil { origin.image = path }
        return origin
    }
}

extension CloudInitAccount {
    /// The account Hangar's ready images have, which Hangar's ready Linux VMs get too.
    package static let hangarImage = CloudInitAccount(username: MacImage.user, password: MacImage.password)
}
