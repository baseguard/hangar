import Foundation
import HangarDisks
import HangarSupport
import Virtualization

package enum LinuxInstaller {
    @concurrent
    @discardableResult
    package static func createVM(
        name: String, iso: URL?, diskImage: URL? = nil, account: CloudInitAccount? = nil,
        userData: String? = nil, options: CreateOptions,
        progress: @escaping ProgressHandler
    ) async throws -> VMBundle {
        if account != nil || userData != nil {
            guard diskImage != nil else { throw HangarError("Cloud-init settings need a cloud image (--disk-image).") }
            try account?.validate()
            try userData.map(CloudInit.validate(userData:))
        }
        return try await VMLibrary.create(name: name) { staging in
            _ = try VZEFIVariableStore(creatingVariableStoreAt: staging.nvramURL, options: [])
            if let diskImage {
                if QCOW2.isImage(diskImage) {
                    try QCOW2.convert(diskImage, to: staging.diskURL, progress: progress)
                } else {
                    progress(CreationProgress(phase: "Copying disk image"))
                    try VMLibrary.cloneFile(from: diskImage, to: staging.diskURL)
                }
                if staging.diskSize < options.diskSize {
                    try staging.resizeDisk(to: options.diskSize)
                }
            } else {
                try SparseFile.create(at: staging.diskURL, size: options.diskSize)
            }

            var config = try VMConfig.newVM(.linux, options: options)
            config.isoPath = iso?.path
            if account != nil || userData != nil {
                progress(CreationProgress(phase: "Writing the cloud-init settings"))
                try CloudInit.writeSeed(account: account, userData: userData, hostname: name, to: staging.cloudInitURL)
                config.sshUser = account?.username
            }
            try staging.saveConfig(config)
        }
    }
}
