import Foundation
import HangarSupport

/// Where a new VM comes from. Hangar.app and `hangar create` both make their VMs through `createVM`, so each
/// source is downloaded and installed the same way. Paths may also be https URLs; they are downloaded first.
package enum VMSource: Sendable {
    /// An installer ISO, a raw disk image, or neither for an empty VM.
    case linux(iso: String?, diskImage: String?, account: CloudInitAccount?, userData: String?)
    case linuxCloudImage(LinuxCloudImage, account: CloudInitAccount?, userData: String?)
    case macOS(ipsw: String, account: MacProvisioning?)
    case macImage(String, account: MacProvisioning?)
    case windows(iso: String, account: WindowsInstaller.Account)
    case registryImage(
        String, os: GuestOS, macAccount: MacProvisioning?, linuxAccount: CloudInitAccount?,
        userData: String? = nil, plainHTTP: Bool = false)
    /// An image saved to a file by `hangar export`.
    case imageFile(
        URL, os: GuestOS, macAccount: MacProvisioning?, linuxAccount: CloudInitAccount?, userData: String?)

    package var os: GuestOS {
        switch self {
        case .linux, .linuxCloudImage: .linux
        case .macOS, .macImage: .macOS
        case .windows: .windows
        case .registryImage(_, let os, _, _, _, _), .imageFile(_, let os, _, _, _): os
        }
    }

    /// What a VM made from this one says it came from, with local files as full paths.
    package var origin: VMTemplate.Origin {
        switch self {
        case .linux(let iso, let diskImage, _, _):
            VMTemplate.Origin(diskImage: diskImage.map(Self.fullPath), iso: iso.map(Self.fullPath))
        case .linuxCloudImage(let image, _, _): VMTemplate.Origin(cloudImage: image)
        case .macOS(let ipsw, _): VMTemplate.Origin(ipsw: Self.fullPath(ipsw))
        case .macImage(let image, _): VMTemplate.Origin(image: image)
        case .windows(let iso, _): VMTemplate.Origin(iso: Self.fullPath(iso))
        case .registryImage(let image, _, _, _, _, _): VMTemplate.Origin(image: image)
        case .imageFile(let file, _, _, _, _): VMTemplate.Origin(image: file.path)
        }
    }

    private var userData: String? {
        switch self {
        case .linux(_, _, _, let userData), .linuxCloudImage(_, _, let userData),
            .registryImage(_, _, _, _, let userData, _), .imageFile(_, _, _, _, let userData):
            userData
        case .macOS, .macImage, .windows: nil
        }
    }

    private static func fullPath(_ location: String) -> String {
        guard location != "latest", !location.lowercased().hasPrefix("https://") else { return location }
        return URL(userPath: location).standardizedFileURL.path
    }

    /// Records where the VM came from, so a template saved from it can make another.
    @concurrent
    @discardableResult
    package func createVM(named name: String, options: CreateOptions, progress: @escaping ProgressHandler)
        async throws -> VMBundle
    {
        let bundle = try await install(named: name, options: options, progress: progress)
        let origin = origin
        let userData = userData
        try bundle.updateConfig { config in
            config.origin = origin
            config.cloudInit = userData
        }
        return bundle
    }

    private func install(named name: String, options: CreateOptions, progress: @escaping ProgressHandler)
        async throws -> VMBundle
    {
        switch self {
        case .linux(let iso, let diskImage, let account, let userData):
            let isoURL = try await Self.localFile(iso, progress: progress)
            let diskURL = try await Self.localFile(diskImage, progress: progress)
            return try await LinuxInstaller.createVM(
                name: name, iso: isoURL, diskImage: diskURL, account: account, userData: userData,
                options: options, progress: progress)
        case .linuxCloudImage(let image, let account, let userData):
            let disk = try await image.disk(progress: progress)
            return try await LinuxInstaller.createVM(
                name: name, iso: nil, diskImage: disk, account: account, userData: userData,
                options: options, progress: progress)
        case .macOS(let ipsw, let account):
            return try await MacInstaller.createVM(
                name: name, source: ipsw, options: options, provisioning: account, progress: progress)
        case .macImage(let image, let account):
            return try await MacImage.createVM(
                name: name, image: image, options: options, provisioning: account, progress: progress)
        case .windows(let iso, let account):
            let isoURL = try await Downloader.localFile(for: iso, progress: progress)
            return try await WindowsInstaller.createVM(
                name: name, iso: isoURL, account: account, options: options, progress: progress)
        case .registryImage(let image, let os, let macAccount, let linuxAccount, let userData, let plainHTTP):
            let reference = try ImageReference(image, plainHTTP: plainHTTP)
            let credentials = try RegistryCredentials.forRegistry(reference.registry)
            return try await VMImage.createVM(
                name: name, image: reference, os: os, options: options, macAccount: macAccount,
                linuxAccount: linuxAccount, userData: userData, credentials: credentials, progress: progress)
        case .imageFile(let file, let os, let macAccount, let linuxAccount, let userData):
            return try await VMImage.createVM(
                name: name, imageFile: file, os: os, options: options, macAccount: macAccount,
                linuxAccount: linuxAccount, userData: userData, progress: progress)
        }
    }

    private static func localFile(_ location: String?, progress: @escaping ProgressHandler) async throws -> URL? {
        guard let location else { return nil }
        return try await Downloader.localFile(for: location, progress: progress)
    }
}
