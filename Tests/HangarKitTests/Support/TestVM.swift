import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

/// A VM that finished its first start, so it can be pushed or exported as an image.
enum TestVM {
    static let macOSBuild = "26A434"

    static var hardwareModel: Data {
        get throws {
            try #require(
                Data(
                    base64Encoded:
                        "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc"
                ))
        }
    }

    static func make(_ os: GuestOS = .macOS, named name: String = "builder", diskSize: Int = 3 << 20) throws
        -> VMBundle
    {
        let bundle = VMBundle(url: HangarPaths.vms.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try bundle.saveConfig(try startedConfig(for: os))
        try writeDisk(at: bundle.diskURL, size: diskSize)
        try Data("nvram".utf8).write(to: bundle.nvramURL)
        try installMacTemplate(diskSize: diskSize)
        return bundle
    }

    private static func startedConfig(for os: GuestOS) throws -> VMConfig {
        var config = VMConfig(
            os: os, cpuCount: 4, memorySize: 8 << 30, display: os.defaultDisplay,
            network: NetworkSettings(mode: .managed, macAddress: VMConfig.randomMACAddress()))
        if os == .macOS { config.hardwareModel = try hardwareModel }
        config.firstStartedAt = Date()
        return config
    }

    private static func writeDisk(at url: URL, size: Int) throws {
        try SparseFile.create(at: url, size: UInt64(size))
        var pattern = Data(count: 2 << 20)
        for index in stride(from: 4096, to: pattern.count, by: 7919) {
            pattern[index] = UInt8(truncatingIfNeeded: index)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: pattern)
        try handle.close()
    }

    private static func installMacTemplate(diskSize: Int) throws {
        let template = MacTemplates.directory.appendingPathComponent(macOSBuild, isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try JSON.write(
            MacTemplates.Info(
                buildVersion: macOSBuild, version: "27.0.1", majorVersion: 27, hardwareModel: try hardwareModel,
                minimumCPUCount: 2, minimumMemorySize: 4 << 30, diskSize: UInt64(diskSize)),
            to: template.appendingPathComponent("template.json"))
    }
}
