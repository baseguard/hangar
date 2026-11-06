import Foundation
import HangarSupport

/// A disk image hdiutil attached: its whole-disk device and the volumes it mounted.
package struct DiskImage {
    static let hdiutil = "/usr/bin/hdiutil"

    package let device: String
    package let volumes: [String: URL]
    /// False for an image that was attached before this attach, which stays for whoever attached it.
    private let isOwned: Bool

    package var mountPoints: [URL] { Array(volumes.values) }

    /// The volumes mount in folders under `mountRoot` when one is given, else under /Volumes.
    package static func attach(_ url: URL, readOnly: Bool, mount: Bool = true, mountRoot: URL? = nil) throws
        -> DiskImage
    {
        let path = url.resolvingSymlinksInPath().path
        let isAlreadyAttached = try attachedImages().contains { $0.path == path || $0.path == url.path }

        let arguments = attachArguments(for: url, readOnly: readOnly, mount: mount, mountRoot: mountRoot)
        let output = try ProcessUtil.run(hdiutil, arguments)
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]], let device = wholeDisk(in: entities)
        else {
            throw HangarError("hdiutil could not attach \(url.lastPathComponent).")
        }

        return DiskImage(device: device, volumes: volumes(in: entities), isOwned: !isAlreadyAttached)
    }

    /// Only an image this attach made is detached.
    package func detach() {
        guard isOwned else { return }
        do {
            _ = try ProcessUtil.run(Self.hdiutil, ["detach", "-force", device])
        } catch {
            HangarLog.warning("Could not detach \(device): \(error)")
        }
    }

    /// For a staging folder that is removed: an image that stays attached only keeps the folder's disk busy.
    package static func detachAll(under directory: URL) {
        let prefixes = [directory.path + "/", directory.resolvingSymlinksInPath().path + "/"]
        let images: [(path: String, device: String)]
        do {
            images = try attachedImages()
        } catch {
            HangarLog.warning("The disk images under \(directory.path) stay attached: \(error)")
            return
        }

        for image in images where prefixes.contains(where: image.path.hasPrefix) {
            do {
                _ = try ProcessUtil.run(hdiutil, ["detach", "-force", image.device])
            } catch {
                HangarLog.warning("Could not detach \(image.path): \(error)")
            }
        }
    }

    /// Every image hdiutil has attached, each by its whole disk. A list that can't be read is an error, since
    /// "nothing is attached" would let an attach claim an image that someone else has open.
    static func attachedImages() throws -> [(path: String, device: String)] {
        let output = try ProcessUtil.run(hdiutil, ["info", "-plist"])
        return try attachedImages(in: output)
    }

    static func attachedImages(in plist: Data) throws -> [(path: String, device: String)] {
        guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            throw HangarError("hdiutil info gave no list of attached images.")
        }

        let images = info["images"] as? [[String: Any]] ?? []
        return images.compactMap { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard let path = image["image-path"] as? String, let device = wholeDisk(in: entities) else { return nil }
            return (path, device)
        }
    }

    /// ISOs are attached as they are; anything else is a raw disk, which hdiutil won't guess.
    private static func attachArguments(for url: URL, readOnly: Bool, mount: Bool, mountRoot: URL?) -> [String] {
        var arguments = ["attach", "-plist", "-nobrowse", "-noverify", "-noautofsck"]
        if readOnly { arguments.append("-readonly") }
        if !mount { arguments.append("-nomount") }
        if let mountRoot { arguments += ["-mountroot", mountRoot.path] }
        if url.pathExtension.lowercased() != "iso" { arguments += ["-imagekey", "diskimage-class=CRawDiskImage"] }
        return arguments + [url.path]
    }

    /// The shortest device entry is the whole disk; the others are its slices.
    private static func wholeDisk(in entities: [[String: Any]]) -> String? {
        entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }

    /// Mount points by volume kind ("msdos", "hfs", …).
    private static func volumes(in entities: [[String: Any]]) -> [String: URL] {
        var volumes: [String: URL] = [:]
        for entity in entities {
            guard let mountPoint = entity["mount-point"] as? String else { continue }
            let kind = entity["volume-kind"] as? String ?? "unknown"
            volumes[kind] = URL(fileURLWithPath: mountPoint, isDirectory: true)
        }
        return volumes
    }
}
