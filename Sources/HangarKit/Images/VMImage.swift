import Foundation
import HangarSupport
import Virtualization

package enum VMImage {
    static let artifactType = "application/vnd.baseguard.hangar.vm.v1"
    static let imageConfigType = "application/vnd.oci.image.config.v1+json"
    static let configType = "application/vnd.baseguard.hangar.config.v1+json"
    static let nvramType = "application/vnd.baseguard.hangar.nvram.v1"
    static let diskType = "application/vnd.baseguard.hangar.disk.v1+lzfse"
    static let offsetKey = "io.baseguard.hangar.offset"
    static let lengthKey = "io.baseguard.hangar.length"
    static let plainDigestKey = "io.baseguard.hangar.plain-digest"
    static let chunkSize = 256 << 20
    static let transferAttempts = 5
    static let removedWhileInUse = HangarError("The downloaded image was removed while it was in use; try again.")
    static let maximumChunk = 512 << 20
    static let maximumDiskSize: UInt64 = 2 << 40
    static let maximumLayers = Int(maximumDiskSize / UInt64(chunkSize)) + 2
    static let maximumNVRAM = 64 << 20
    static let maximumManifest = 4 << 20
    static let maximumConfig = 65_536
    /// LZFSE can grow a part that doesn't compress by a little; a layer past this is not a chunk.
    static let compressionSlack = 1 << 20
    static let parallelTransfers = 4

    package struct Config: Codable, Sendable, Equatable {
        package var os: GuestOS
        package var diskSize: UInt64
        package var account: String?
        package var macOS: MacDetails?
        package var remoteDesktop: Bool?

        /// Linux images take a cloud-init account; a macOS image only while it has never been set up.
        package var takesNewAccount: Bool {
            switch os {
            case .linux: true
            case .macOS: account == nil && macOS?.version != nil
            case .windows: false
            }
        }

        package var title: String {
            guard let macOS, let version = macOS.version, let build = macOS.build else {
                return "\(os.displayName) image"
            }
            return "macOS \(version) (\(build))" + (macOS.xcode.map { " with Xcode \($0)" } ?? "")
        }
    }

    package struct MacDetails: Codable, Sendable, Equatable {
        /// Nil for a VM someone exported: Hangar doesn't open a guest's disk to read it, and that VM was set up
        /// already, so it keeps its own accounts.
        package var version: String?
        package var build: String?
        package var xcode: String?
        var hardwareModel: Data
        var minimumCPUCount: Int
        var minimumMemorySize: UInt64

        var name: String { version.map { "macOS \($0)" } ?? "macOS" }

        func check() throws {
            guard (1...VZVirtualMachineConfiguration.maximumAllowedCPUCount).contains(minimumCPUCount),
                (VZVirtualMachineConfiguration
                    .minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize)
                    .contains(minimumMemorySize)
            else {
                throw HangarError("This image asks for resources a VM can't have.")
            }
            guard VZMacHardwareModel(dataRepresentation: hardwareModel)?.isSupported == true else {
                throw HangarError("This Mac can't run the \(name) in this image.")
            }
        }
    }

    struct Manifest: Codable {
        var schemaVersion = 2
        var mediaType = RegistryClient.manifestType
        var artifactType: String? = VMImage.artifactType
        var config: Descriptor
        var layers: [Descriptor]
        var annotations: [String: String]?
    }

    struct Descriptor: Codable {
        var mediaType: String
        var digest: String
        var size: Int64
        var annotations: [String: String]?
    }

    struct Chunk: Equatable {
        var offset: UInt64
        var length: Int
        var plainDigest: String
        var digest: String
        var size: Int64
    }

    struct Layout {
        let config: Descriptor
        let nvram: Descriptor
        let chunks: [Chunk]

        init(_ manifest: Manifest) throws {
            guard Self.isVMImage(manifest) else { throw Self.unsupported }
            let config = manifest.layers[0]
            let nvram = manifest.layers[1]
            guard Self.isConfigLayer(config), Self.isNVRAMLayer(nvram) else { throw Self.unsupported }

            let chunks = try manifest.layers.dropFirst(2).map(Self.chunk(from:)).sorted { $0.offset < $1.offset }
            guard Self.doNotOverlap(chunks), Self.sameDigestsDescribeSameData(chunks) else { throw Self.unsupported }
            self.config = config
            self.nvram = nvram
            self.chunks = chunks
        }

        private static var unsupported: HangarError {
            HangarError("This image's manifest describes a disk Hangar can't create.")
        }

        private static func isVMImage(_ manifest: Manifest) -> Bool {
            manifest.artifactType == VMImage.artifactType && manifest.config.mediaType == VMImage.imageConfigType
                && Digests.isValid(manifest.config.digest)
                && (2...VMImage.maximumLayers).contains(manifest.layers.count)
        }

        private static func isConfigLayer(_ layer: Descriptor) -> Bool {
            layer.mediaType == VMImage.configType && (1...Int64(VMImage.maximumConfig)).contains(layer.size)
                && Digests.isValid(layer.digest)
        }

        private static func isNVRAMLayer(_ layer: Descriptor) -> Bool {
            layer.mediaType == VMImage.nvramType && (1...Int64(VMImage.maximumNVRAM)).contains(layer.size)
                && Digests.isValid(layer.digest)
        }

        private static func chunk(from layer: Descriptor) throws -> Chunk {
            guard layer.mediaType == VMImage.diskType,
                let offset = layer.annotations?[VMImage.offsetKey].flatMap(UInt64.init),
                let length = layer.annotations?[VMImage.lengthKey].flatMap(Int.init),
                let plain = layer.annotations?[VMImage.plainDigestKey], Digests.isValid(plain),
                Digests.isValid(layer.digest),
                (1...VMImage.maximumChunk).contains(length), offset % UInt64(DiskRegion.blockSize) == 0,
                offset <= VMImage.maximumDiskSize,
                (1...Int64(length) + Int64(length / 16) + Int64(VMImage.compressionSlack)).contains(layer.size)
            else { throw unsupported }
            return Chunk(offset: offset, length: length, plainDigest: plain, digest: layer.digest, size: layer.size)
        }

        private static func doNotOverlap(_ sortedChunks: [Chunk]) -> Bool {
            zip(sortedChunks, sortedChunks.dropFirst()).allSatisfy { previous, next in
                previous.offset + UInt64(previous.length) <= next.offset
            }
        }

        private static func sameDigestsDescribeSameData(_ chunks: [Chunk]) -> Bool {
            var firstWithDigest: [String: Chunk] = [:]
            for chunk in chunks {
                guard let first = firstWithDigest[chunk.digest] else {
                    firstWithDigest[chunk.digest] = chunk
                    continue
                }
                guard first.length == chunk.length, first.plainDigest == chunk.plainDigest else { return false }
            }
            return true
        }

        func check(_ config: Config) throws {
            guard config.diskSize <= VMImage.maximumDiskSize,
                chunks.allSatisfy({ $0.offset + UInt64($0.length) <= config.diskSize })
            else {
                throw HangarError("This image's disk parts don't fit its disk.")
            }

            if let account = config.account, !VMConfig.isValidUserName(account) {
                throw HangarError("This image names an account Hangar can't use.")
            }

            if config.remoteDesktop != nil, config.os != .windows {
                throw HangarError("This image's settings don't fit a \(config.os.displayName) VM.")
            }

            switch (config.os, config.macOS) {
            case (.macOS, let macOS?):
                try macOS.check()
            case (.linux, nil), (.windows, nil):
                break
            default:
                throw HangarError("This image's settings don't fit a \(config.os.displayName) VM.")
            }
        }

        var downloadSize: Int64 { chunks.reduce(nvram.size) { $0 + $1.size } }
    }

    struct Cached: Sendable {
        let folder: URL
        let config: Config

        var disk: URL { folder.appendingPathComponent("disk.img") }
        var nvram: URL { folder.appendingPathComponent("nvram.bin") }
    }

    struct Record: Codable {
        var name: String
        var reference: String
        var config: Config
        var parts: [Part]
        var pulledAt: Date

        var title: String {
            name.contains("/") ? "\(config.title) from \(name)" : config.title
        }
    }

    struct Part: Codable {
        var offset: UInt64
        var length: Int
        var plainDigest: String
    }

    struct LocalPart {
        let disk: URL
        let offset: UInt64
    }

    static var cache: URL { HangarPaths.cache.appendingPathComponent("images", isDirectory: true) }

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, image reference: ImageReference, os: GuestOS, options: CreateOptions,
        macAccount: MacProvisioning? = nil, linuxAccount: CloudInitAccount? = nil, userData: String? = nil,
        credentials: RegistryCredentials? = nil, progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        try VMLibrary.validate(name: name)
        let cacheName = reference.tag.map { "\(reference.registry)/\(reference.repository):\($0)" }
        let pinnedReference = try await pinned(reference, credentials: credentials)
        progress(CreationProgress(phase: "Using \(pinnedReference)"))
        let cached = try await pull(
            pinnedReference, named: cacheName ?? pinnedReference.description, credentials: credentials,
            accept: accepting(
                os, options: options, macAccount: macAccount, linuxAccount: linuxAccount, userData: userData),
            progress: progress)
        return try await createVM(
            name: name, from: cached, source: pinnedReference.description, options: options, macAccount: macAccount,
            linuxAccount: linuxAccount, userData: userData, progress: progress)
    }

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, imageFile file: URL, os: GuestOS, options: CreateOptions,
        macAccount: MacProvisioning? = nil, linuxAccount: CloudInitAccount? = nil, userData: String? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        try VMLibrary.validate(name: name)
        let archive = try ImageArchive.open(file)
        progress(CreationProgress(phase: "Using \(file.path)"))
        let cached = try await pull(
            archive.manifestDigest, from: archive, named: file.lastPathComponent, reference: file.path,
            accept: accepting(
                os, options: options, macAccount: macAccount, linuxAccount: linuxAccount, userData: userData),
            progress: progress)
        return try await createVM(
            name: name, from: cached, source: nil, options: options, macAccount: macAccount,
            linuxAccount: linuxAccount, userData: userData, progress: progress)
    }

    private static func accepting(
        _ os: GuestOS, options: CreateOptions, macAccount: MacProvisioning?, linuxAccount: CloudInitAccount?,
        userData: String?
    ) -> (Config) throws -> Void {
        { config in
            guard config.os == os else {
                throw HangarError("This is a \(config.os.displayName) image, not \(os.displayName).")
            }
            try check(config, options: options, macAccount: macAccount, linuxAccount: linuxAccount, userData: userData)
        }
    }

    @concurrent
    package static func inspect(_ reference: ImageReference, credentials: RegistryCredentials?) async throws -> (
        pinned: ImageReference, config: Config
    ) {
        let client = RegistryClient(image: reference, credentials: credentials)
        let (manifest, digest) = try await client.manifest(reference.tagOrDigest)
        return (reference.adding(digest: digest), try await settings(of: manifest, from: client).config)
    }

    @concurrent
    package static func inspect(imageFile file: URL) async throws -> Config {
        let archive = try ImageArchive.open(file)
        let manifest = try await archive.manifest(digest: archive.manifestDigest)
        return try await settings(of: manifest, from: archive).config
    }

    static func settings(of manifest: Data, from source: any BlobSource) async throws -> (
        layout: Layout, config: Config
    ) {
        let layout = try Layout(try JSONDecoder().decode(Manifest.self, from: manifest))
        let config = try JSONDecoder().decode(
            Config.self, from: try await source.blob(layout.config.digest, limit: maximumConfig))
        try layout.check(config)
        return (layout, config)
    }

    @concurrent
    package static func pinned(_ reference: ImageReference, credentials: RegistryCredentials?) async throws
        -> ImageReference
    {
        guard reference.digest == nil else { return reference }
        let (_, digest) = try await RegistryClient(image: reference, credentials: credentials).manifest(
            reference.tagOrDigest)
        return reference.adding(digest: digest)
    }

    static func createVM(
        name: String, from cached: Cached, source: String?, options: CreateOptions, macAccount: MacProvisioning? = nil,
        linuxAccount: CloudInitAccount? = nil, userData: String? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        let image = cached.config
        try VMLibrary.validate(name: name)
        try check(image, options: options, macAccount: macAccount, linuxAccount: linuxAccount, userData: userData)
        progress(CreationProgress(phase: "Creating \(name)"))
        let inUse = FileLock(url: cached.folder.appendingPathComponent("pull.lock"))
        while try !inUse.tryLock(.exclusive) {
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { inUse.unlock() }
        guard inUse.isStillAtItsPath, FileManager.default.fileExists(atPath: cached.disk.path) else {
            throw removedWhileInUse
        }
        CacheStore.markUsed(cached.folder.appendingPathComponent("image.json"))
        try macAccount?.savePassword()
        do {
            return try await VMLibrary.create(name: name) { staging in
                try VMLibrary.cloneFile(from: cached.disk, to: staging.diskURL)
                try VMLibrary.cloneFile(from: cached.nvram, to: staging.nvramURL)
                if options.diskSize > image.diskSize {
                    try staging.resizeDisk(to: options.diskSize)
                }

                var config = try vmConfig(image, options: options)
                config.provisioning = macAccount
                config.sshUser = macAccount?.username ?? linuxAccount?.username ?? image.account
                config.image = source
                if image.os == .linux {
                    try CloudInit.writeSeedForCopiedDisk(
                        account: linuxAccount, userData: userData, hostname: name, to: staging.cloudInitURL)
                }
                try staging.saveConfig(config)
            }
        } catch {
            macAccount?.forgetPassword()
            throw error
        }
    }

    static func check(
        _ image: Config, options: CreateOptions, macAccount: MacProvisioning?,
        linuxAccount: CloudInitAccount?, userData: String?
    ) throws {
        if let macAccount {
            guard image.os == .macOS else { throw HangarError("A macOS account goes with a macOS image.") }
            if let account = image.account {
                throw HangarError(
                    "This image already has the account '\(account)'; only an image without one creates yours.")
            }
            guard let version = image.macOS?.version else {
                throw HangarError(
                    "This image is a macOS that was set up already and keeps its own accounts; leave out --user.")
            }
            try macAccount.validate()
            try MacProvisioning.checkSupported(majorVersion: Int(version.prefix { $0 != "." }) ?? 0)
        }
        if linuxAccount != nil || userData != nil {
            guard image.os == .linux else { throw HangarError("Cloud-init settings go with a Linux image.") }
            try linuxAccount?.validate()
            try userData.map(CloudInit.validate(userData:))
        }
        guard let macOS = image.macOS else { return }
        if let cpus = options.cpuCount, cpus < macOS.minimumCPUCount {
            throw HangarError("\(macOS.name) needs at least \(macOS.minimumCPUCount) CPUs.")
        }
        if let memory = options.memorySize, memory < macOS.minimumMemorySize {
            throw HangarError(
                "\(macOS.name) needs at least \(ByteSize.format(macOS.minimumMemorySize)) of memory.")
        }
    }

    static func vmConfig(_ image: Config, options: CreateOptions) throws -> VMConfig {
        var config = try VMConfig.newVM(image.os, options: options)
        config.remoteDesktop = image.remoteDesktop ?? config.remoteDesktop
        guard let macOS = image.macOS else { return config }
        config.cpuCount = max(config.cpuCount, macOS.minimumCPUCount)
        config.memorySize = max(config.memorySize, macOS.minimumMemorySize)
        config.hardwareModel = macOS.hardwareModel
        return config
    }

    static func localParts(excluding folder: URL) -> [String: LocalPart] {
        var parts: [String: LocalPart] = [:]
        for (other, record) in cachedImages() where other.lastPathComponent != folder.lastPathComponent {
            for part in record.parts {
                parts[part.plainDigest] = LocalPart(disk: other.appendingPathComponent("disk.img"), offset: part.offset)
            }
        }
        return parts
    }

    static func cachedImages() -> [(folder: URL, record: Record)] {
        cacheFolders().compactMap { folder in record(in: folder).map { (folder, $0) } }
    }

    static func cacheFolders() -> [URL] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        return folders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    static func record(in folder: URL) -> Record? {
        try? JSON.read(Record.self, from: folder.appendingPathComponent("image.json"))
    }
}
