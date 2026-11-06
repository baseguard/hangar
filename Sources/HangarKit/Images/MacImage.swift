import Foundation
import HangarSupport
import Virtualization

package enum MacImage {
    package static let user = "admin"
    package static let password = "admin"
    package static let fullName = "Administrator"
    package static let names = ["vanilla", "base", "xcode"]

    static let repository = "ghcr.io/baseguard/hangar-macos"

    package static func reference(for image: String) throws -> ImageReference {
        guard names.contains(image) else {
            throw HangarError("Hangar's macOS images are vanilla, base and xcode, not '\(image)'.")
        }
        return try ImageReference("\(repository):\(image)")
    }

    @concurrent
    @discardableResult
    package static func createVM(
        name: String, image: String, options: CreateOptions, provisioning: MacProvisioning? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        try provisioning?.validate()
        return try await VMImage.createVM(
            name: name, image: try reference(for: image), os: .macOS, options: options,
            macAccount: provisioning, progress: progress)
    }

    package static func details(of bundle: VMBundle, build: String, xcode: String?) throws -> VMImage.MacDetails {
        let vm = try bundle.loadConfig()
        guard vm.os == .macOS, let model = vm.hardwareModel else {
            throw HangarError("'\(bundle.name)' isn't a macOS VM.")
        }
        guard let template = MacTemplates.info(build: build) else {
            throw HangarError("Hangar's cache has no installed macOS \(build) to take its requirements from.")
        }
        return VMImage.MacDetails(
            version: template.version, build: build, xcode: xcode, hardwareModel: model,
            minimumCPUCount: template.minimumCPUCount, minimumMemorySize: template.minimumMemorySize)
    }

    /// Whoever creates a VM from it picks the CPUs and memory, as for any macOS VM.
    static func exportedDetails(of vm: VMConfig) throws -> VMImage.MacDetails {
        guard let model = vm.hardwareModel else { throw HangarError("This macOS VM has no hardware model to export.") }
        return VMImage.MacDetails(
            version: nil, build: nil, xcode: nil, hardwareModel: model,
            minimumCPUCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            minimumMemorySize: VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    }
}
