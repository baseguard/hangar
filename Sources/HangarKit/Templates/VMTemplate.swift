import Foundation
import HangarSecrets
import HangarSupport

/// A VM's recipe in a file to share or keep with a project (`.hangarvm`): what it is made from, its size and settings,
/// its traffic rules, the secrets it expects and the commands that set it up. Nothing of the machine it was saved from
/// goes in: no disk, addresses, identifiers, passwords or secret values.
package struct VMTemplate: Codable, Hashable, Sendable {
    package static let fileExtension = "hangarvm"
    package static let sizeLimit = 1 << 20

    /// What a VM is made from; at most one is set. A file is a path on the Mac the template was saved on.
    package struct Origin: Codable, Hashable, Sendable {
        /// A registry image, an image file from `hangar export`, or a macOS image (vanilla, base or xcode).
        package var image: String?
        package var cloudImage: LinuxCloudImage?
        /// A Linux disk: a file or an https URL.
        package var diskImage: String?
        /// An installer ISO for Linux or Windows: a file or an https URL.
        package var iso: String?
        /// A macOS restore image: a file, an https URL or latest.
        package var ipsw: String?

        package init(
            image: String? = nil, cloudImage: LinuxCloudImage? = nil, diskImage: String? = nil, iso: String? = nil,
            ipsw: String? = nil
        ) {
            self.image = image
            self.cloudImage = cloudImage
            self.diskImage = diskImage
            self.iso = iso
            self.ipsw = ipsw
        }
    }

    /// A secret the VM expects; its value is asked for where the template is used.
    package struct Secret: Codable, Hashable, Sendable {
        package var name: String
        package var hosts: [String]
        /// A header the value is sent in on every request to the hosts, after `prefix`.
        package var header: String?
        package var prefix: String?
    }

    package var os: GuestOS
    /// `nil` asks for it where the template is used.
    package var from: Origin?
    package var cpu: Int?
    /// In GB.
    package var memory: Int?
    /// In GB.
    package var disk: Int?
    package var network: NetworkMode?
    package var display: DisplaySettings?
    package var traffic: TrafficRuleFile?
    package var secrets: [Secret]?
    package var sharedFolders: [SharedFolder]?
    package var clipboard: Bool?
    package var audio: Bool?
    package var rosetta: Bool?
    /// Linux: a #cloud-config file or a #! script that cloud-init runs on the first start.
    package var cloudInit: String?
    /// Commands run in order through Hangar's agent once the VM has started for the first time.
    package var setup: [String]?

    static let keys: Set<String> = [
        "os", "from", "cpu", "memory", "disk", "network", "display", "traffic", "secrets", "sharedFolders",
        "clipboard", "audio", "rosetta", "cloudInit", "setup",
    ]

    package func encoded() throws -> Data {
        try JSON.encoder.encode(self)
    }

    /// Refuses fields Hangar doesn't know, so a misspelled one isn't silently dropped.
    package static func decode(_ data: Data) throws -> VMTemplate {
        guard data.count <= sizeLimit else { throw HangarError("A Hangar template can be at most 1 MB.") }
        if let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            try JSON.refuseUnknownKeys(in: fields, known: keys, of: "This template")
        }

        let template: VMTemplate
        do {
            template = try JSON.decoder.decode(VMTemplate.self, from: data)
        } catch let error as DecodingError {
            throw HangarError("This isn't a Hangar template: \(JSON.problem(error)).")
        }
        try template.validate()
        return template
    }

    package func validate() throws {
        try from?.validate(for: os)
        try validateSizes()
        try validateDisplay()
        if cloudInit != nil, os != .linux { throw HangarError("Only a Linux template can have cloudInit.") }
        if let cloudInit { try CloudInit.validate(userData: cloudInit) }
        if cloudInit != nil, from?.iso != nil {
            throw HangarError("cloudInit goes with a cloud image, a disk image or an image, not an iso.")
        }
        if secrets?.isEmpty == false, let network, network != .managed {
            throw HangarError("Secrets need Hangar's managed network; set \"network\" to managed.")
        }
        if rosetta == true, os != .linux { throw HangarError("Only a Linux template can turn on rosetta.") }
        for secret in secrets ?? [] { try secret.validate() }
        for folder in sharedFolders ?? [] where !SharedFolder.isValidName(folder.name) {
            throw HangarError("'\(folder.name)' can't name a shared folder.")
        }
        for step in setup ?? [] where step.trimmingCharacters(in: .whitespaces).isEmpty || step.contains("\0") {
            throw HangarError("A setup step is empty or has a NUL character.")
        }
        _ = try traffic?.normalized()
    }

    private func validateSizes() throws {
        if let cpu, cpu < 1 { throw HangarError("cpu must be at least 1.") }
        if let memory, memory < 1 { throw HangarError("memory is in GB and must be at least 1.") }
        if let disk, disk < 1 { throw HangarError("disk is in GB and must be at least 1.") }
    }

    /// The screen sizes `hangar set --display` accepts.
    private func validateDisplay() throws {
        guard let display else { return }
        let widths = VMSettings.screenWidths
        let heights = VMSettings.screenHeights
        guard widths.contains(display.width), heights.contains(display.height), display.pixelsPerInch > 0 else {
            throw HangarError(
                "display must be between \(widths.lowerBound)x\(heights.lowerBound) and "
                    + "\(widths.upperBound)x\(heights.upperBound), with pixelsPerInch above 0.")
        }
    }
}

extension VMTemplate.Origin {
    private var setCount: Int {
        [image, cloudImage?.rawValue, diskImage, iso, ipsw].count { $0 != nil }
    }

    func validate(for os: GuestOS) throws {
        guard setCount <= 1 else { throw HangarError("from names more than one thing to make the VM from.") }
        if cloudImage != nil || diskImage != nil, os != .linux {
            throw HangarError("cloudImage and diskImage make Linux VMs.")
        }
        if iso != nil, os == .macOS { throw HangarError("A macOS VM is made from an ipsw or an image, not an iso.") }
        if ipsw != nil, os != .macOS { throw HangarError("Only a macOS VM is made from an ipsw.") }
    }

    /// The file this Mac must have to make the VM, if it is made from one rather than a URL, a name or a registry.
    package var localFile: String? {
        if let path = iso ?? diskImage ?? ipsw, Self.isLocalFile(path) { return path }
        if let image, VMImage.isImageFile(image) { return image }
        return nil
    }

    private static func isLocalFile(_ location: String) -> Bool {
        location != "latest" && !location.lowercased().hasPrefix("https://")
    }
}

extension VMTemplate.Secret {
    init(_ rule: SecretRule) {
        name = rule.name
        hosts = rule.hosts
        if let header = rule.header {
            let parts = header.format.components(separatedBy: SecretRule.valueMarker)
            self.header = header.name
            let prefix = parts[0].trimmingCharacters(in: .whitespaces)
            self.prefix = prefix.isEmpty ? nil : prefix
        }
    }

    func validate() throws {
        try SecretRule.validate(name: name)
        for host in hosts { try SecretRule.validate(host: host) }
        if let header = rule().header { try SecretRule.validate(header: header) }
    }

    /// With a placeholder of its own, so no two VMs made from one template share one.
    package func rule() -> SecretRule {
        let format = (prefix.map { $0 + " " } ?? "") + SecretRule.valueMarker
        return SecretRule(name: name, hosts: hosts, header: header.map { .init(name: $0, format: format) })
    }
}

extension VMTemplate {
    /// The recipe of `config`'s VM, as `hangar template save` writes it.
    package init(savedFrom config: VMConfig, diskSize: UInt64) {
        os = config.os
        from = config.origin
        cpu = config.cpuCount
        memory = Int(config.memorySize / ByteSize.gib)
        disk = Int((diskSize + ByteSize.gib - 1) / ByteSize.gib)
        network = config.network.mode
        display = config.display
        traffic = TrafficRuleFile(config.traffic)
        secrets = config.secrets.map { $0.rules.map(Secret.init) }
        sharedFolders = config.sharedFolders.isEmpty ? nil : config.sharedFolders
        clipboard = config.clipboard
        audio = config.audio
        rosetta = config.os == .linux ? config.rosetta : nil
        cloudInit = config.cloudInit
        setup = config.setup
    }

    /// Sets up a VM just made from this template. Shared folders this Mac won't share are skipped and returned.
    package func apply(to config: inout VMConfig) throws -> [SkippedFolder] {
        if let display { config.display = display }
        if let traffic { try config.traffic.apply(traffic) }
        if let secrets, !secrets.isEmpty { config.secrets = SecretSettings(rules: secrets.map { $0.rule() }) }
        if let clipboard { config.clipboard = clipboard }
        if let audio { config.audio = audio }
        if let rosetta { config.rosetta = rosetta }
        config.setup = setup

        let folders = sharedFoldersOnThisMac()
        config.sharedFolders += folders.shared
        return folders.skipped
    }
}

extension VMTemplate {
    package static func read(from url: URL) throws -> VMTemplate {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HangarError("Could not read the template \(url.path): \(error.localizedDescription)")
        }
        return try decode(data)
    }

    package func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
