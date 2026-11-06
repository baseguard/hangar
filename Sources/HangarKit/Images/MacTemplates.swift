import Foundation
import HangarSupport
import Virtualization

package enum MacTemplates {
    struct Info: Codable {
        var buildVersion: String
        var version: String
        var majorVersion: Int
        var hardwareModel: Data
        var minimumCPUCount: Int
        var minimumMemorySize: UInt64
        var diskSize: UInt64
    }

    struct Template {
        let folder: URL
        let info: Info

        var diskURL: URL { folder.appendingPathComponent("disk.img") }
        var nvramURL: URL { folder.appendingPathComponent("nvram.bin") }
    }

    static var directory: URL { HangarPaths.cache.appendingPathComponent("macos", isDirectory: true) }

    private static func folder(for build: String) -> URL {
        directory.appendingPathComponent(build.filter { $0.isLetter || $0.isNumber }, isDirectory: true)
    }

    static func find(build: String, diskSize: UInt64) -> Template? {
        let folder = folder(for: build)
        guard let info = try? JSON.read(Info.self, from: folder.appendingPathComponent("template.json")),
            info.buildVersion == build, info.diskSize == diskSize,
            VZMacHardwareModel(dataRepresentation: info.hardwareModel)?.isSupported == true
        else { return nil }
        let template = Template(folder: folder, info: info)
        guard FileManager.default.fileExists(atPath: template.diskURL.path),
            FileManager.default.fileExists(atPath: template.nvramURL.path)
        else { return nil }
        return template
    }

    static func newest() -> Info? {
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? JSON.read(Info.self, from: $0.appendingPathComponent("template.json")) }
            .max { $0.buildVersion.compare($1.buildVersion, options: .numeric) == .orderedAscending }
    }

    static func info(build: String) -> Info? {
        try? JSON.read(Info.self, from: folder(for: build).appendingPathComponent("template.json"))
    }

    static func keep(_ bundle: VMBundle, as info: Info) {
        do {
            try HangarPaths.createDirectory(directory)
            let staging = directory.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            try VMLibrary.cloneFile(from: bundle.diskURL, to: staging.appendingPathComponent("disk.img"))
            try VMLibrary.cloneFile(from: bundle.nvramURL, to: staging.appendingPathComponent("nvram.bin"))
            try JSON.write(info, to: staging.appendingPathComponent("template.json"))
            let final = folder(for: info.buildVersion)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: staging, to: final)
            let others =
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for other in others
            where other.lastPathComponent != final.lastPathComponent && !other.lastPathComponent.hasPrefix(".") {
                try? FileManager.default.removeItem(at: other)
            }
        } catch {
            HangarLog.warning(
                "Could not keep macOS \(info.version) for faster VM creation: \(error.localizedDescription)")
        }
    }

    static func createVM(
        name: String, from template: Template, options: CreateOptions, provisioning: MacProvisioning?,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        if provisioning != nil { try MacProvisioning.checkSupported(majorVersion: template.info.majorVersion) }
        progress(CreationProgress(phase: "Copying the installed macOS \(template.info.version)"))
        CacheStore.markUsed(template.folder.appendingPathComponent("template.json"))
        try provisioning?.savePassword()

        do {
            return try await VMLibrary.create(name: name) { staging in
                try VMLibrary.cloneFile(from: template.diskURL, to: staging.diskURL)
                try VMLibrary.cloneFile(from: template.nvramURL, to: staging.nvramURL)
                try staging.saveConfig(
                    try MacInstaller.config(options: options, info: template.info, provisioning: provisioning))
            }
        } catch {
            provisioning?.forgetPassword()
            throw error
        }
    }
}
