import Foundation
import HangarDisks
import HangarSupport
import Virtualization

package enum MacInstaller {
    @concurrent
    package static func latestRestoreImage() async throws -> RestoreImageInfo {
        let image = try await VZMacOSRestoreImage.latestSupported
        return RestoreImageInfo(
            url: image.url, buildVersion: image.buildVersion, version: versionString(image.operatingSystemVersion))
    }

    static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    @concurrent
    package static func resolveIPSW(_ source: String, progress: @escaping ProgressHandler) async throws -> URL {
        if source == "latest" {
            progress(CreationProgress(phase: "Looking up the latest macOS"))
            return try await downloadLatest(try await latestRestoreImage(), progress: progress)
        }
        return try await Downloader.localFile(
            for: source, in: HangarPaths.ipswCache, fallbackName: "restore.ipsw", progress: progress)
    }

    private static func downloadLatest(_ latest: RestoreImageInfo, progress: @escaping ProgressHandler) async throws
        -> URL
    {
        progress(CreationProgress(phase: "macOS \(latest.version) (\(latest.buildVersion))"))
        let file = HangarPaths.ipswCache.appendingPathComponent("latest-\(latest.buildVersion).ipsw")
        let ipsw = try await Downloader.cached(
            latest.url, as: file, phase: "Downloading macOS \(latest.version)", progress: progress)
        removeOlderLatestIPSWs(keeping: ipsw)
        return ipsw
    }

    private static func removeOlderLatestIPSWs(keeping kept: URL) {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: HangarPaths.ipswCache, includingPropertiesForKeys: nil))
            ?? []
        for file in files
        where file.lastPathComponent.hasPrefix("latest-") && file.pathExtension == "ipsw"
            && file.lastPathComponent != kept.lastPathComponent
        {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, source: String, options: CreateOptions, provisioning: MacProvisioning?,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        try provisioning?.validate()
        let ipsw: URL
        if source == "latest" {
            progress(CreationProgress(phase: "Looking up the latest macOS"))
            let latest = try await latestRestoreImage()
            if let template = MacTemplates.find(build: latest.buildVersion, diskSize: options.diskSize) {
                return try await MacTemplates.createVM(
                    name: name, from: template, options: options,
                    provisioning: provisioning, progress: progress)
            }
            ipsw = try await downloadLatest(latest, progress: progress)
        } else {
            ipsw = try await resolveIPSW(source, progress: progress)
        }
        return try await createVM(
            name: name, ipsw: ipsw, options: options, provisioning: provisioning, progress: progress)
    }

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, ipsw: URL, options: CreateOptions, provisioning: MacProvisioning?,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        try provisioning?.validate()
        progress(CreationProgress(phase: "Loading restore image"))
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration,
            requirements.hardwareModel.isSupported
        else {
            throw HangarError("This Mac cannot run the macOS version in \(ipsw.lastPathComponent).")
        }

        let info = templateInfo(of: image, requirements: requirements, diskSize: options.diskSize)
        if let template = MacTemplates.find(build: info.buildVersion, diskSize: options.diskSize) {
            return try await MacTemplates.createVM(
                name: name, from: template, options: options,
                provisioning: provisioning, progress: progress)
        }
        if provisioning != nil { try MacProvisioning.checkSupported(majorVersion: info.majorVersion) }

        try provisioning?.savePassword()
        do {
            return try await VMLibrary.create(name: name) { staging in
                _ = try VZMacAuxiliaryStorage(
                    creatingStorageAt: staging.nvramURL,
                    hardwareModel: requirements.hardwareModel, options: [])
                try SparseFile.create(at: staging.diskURL, size: options.diskSize)
                let config = try Self.config(options: options, info: info, provisioning: provisioning)
                try staging.saveConfig(config)
                try await install(bundle: staging, config: config, ipsw: ipsw, progress: progress)
                MacTemplates.keep(staging, as: info)
            }
        } catch {
            provisioning?.forgetPassword()
            throw error
        }
    }

    /// What a template of this restore image is filed under, and what its VMs need.
    private static func templateInfo(
        of image: VZMacOSRestoreImage, requirements: VZMacOSConfigurationRequirements, diskSize: UInt64
    ) -> MacTemplates.Info {
        MacTemplates.Info(
            buildVersion: image.buildVersion,
            version: versionString(image.operatingSystemVersion),
            majorVersion: image.operatingSystemVersion.majorVersion,
            hardwareModel: requirements.hardwareModel.dataRepresentation,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemorySize: requirements.minimumSupportedMemorySize,
            diskSize: diskSize)
    }

    static func config(options: CreateOptions, info: MacTemplates.Info, provisioning: MacProvisioning?) throws
        -> VMConfig
    {
        var config = try VMConfig.newVM(.macOS, options: options)
        config.cpuCount = max(config.cpuCount, info.minimumCPUCount)
        config.memorySize = max(config.memorySize, info.minimumMemorySize)
        config.hardwareModel = info.hardwareModel
        config.provisioning = provisioning
        config.sshUser = provisioning?.username
        return config
    }

    @MainActor
    private static func install(bundle: VMBundle, config: VMConfig, ipsw: URL, progress: @escaping ProgressHandler)
        async throws
    {
        let configuration = try ConfigurationBuilder(bundle: bundle, config: config, purpose: .install).build()
        let vm = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        progress(CreationProgress(phase: "Installing macOS", fraction: 0))
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { installProgress, _ in
            progress(CreationProgress(phase: "Installing macOS", fraction: installProgress.fractionCompleted))
        }
        defer { observation.invalidate() }
        let installProgress = installer.progress
        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            installProgress.cancel()
        }
        if vm.canStop {
            try? await vm.stop()
        }
    }
}
