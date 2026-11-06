import AppKit
import Foundation
import HangarKit
import HangarSupport

/// A VM's devices and shares, changed while it runs where its session allows.
extension VMStore {
    func attachUSB(_ device: USBDevices.Device, to name: String) {
        guard let session = sessions[name] else { return }
        Task {
            do {
                try await USBDevices.shared.attach(device, to: session)
            } catch {
                report(error, doing: "connect \(device.name) to \(name)")
            }
        }
    }

    func detachUSB(_ device: USBDevices.Device) {
        Task {
            do {
                try await USBDevices.shared.detach(device)
            } catch {
                report(error, doing: "disconnect \(device.name)")
            }
        }
    }

    /// `nil` detaches it. Only a VM running in this app can change its ISO while it runs.
    func changeISO(of name: String, to url: URL?) {
        Task {
            do {
                if vm(name)?.isRunning == true {
                    guard let session = sessions[name] else {
                        throw HangarError("Shut down '\(name)' to change its ISO.")
                    }
                    if let url { try await session.attachISO(url) } else { try await session.detachISO() }
                }
                update(name, appliedLive: true) { config in config.isoPath = url?.path }
            } catch {
                report(error, doing: url == nil ? "detach the ISO from \(name)" : "attach the ISO to \(name)")
            }
        }
    }

    /// Each folder gets a share name of its own, numbered when one is taken.
    func addSharedFolders(_ urls: [URL], readOnly: Bool, to name: String) {
        updateSharedFolders(name) { folders in
            for url in urls {
                let proposed = try SharedFolder.make(path: url.path, name: nil, readOnly: readOnly)
                var shareName = proposed.name
                var index = 2
                while folders.contains(where: { $0.name == shareName }) {
                    shareName = "\(proposed.name)-\(index)"
                    index += 1
                }
                folders.append(try SharedFolder.make(path: url.path, name: shareName, readOnly: readOnly))
            }
        }
    }

    func updateSharedFolders(_ name: String, _ change: @escaping @Sendable (inout [SharedFolder]) throws -> Void) {
        guard update(name, appliedLive: true, { config in try change(&config.sharedFolders) }) else { return }
        Task {
            do {
                await saved()
                try await send(.reloadSharedFolders, to: name)
            } catch {
                report(error, doing: "share folders with \(name)")
            }
        }
    }
}
