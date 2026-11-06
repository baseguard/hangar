import Foundation

/// Folders in this Mac's temporary folder that hold items copied out of a guest for a drag to Finder, one per item.
enum DragExports {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.baseguard.hangar.drag", isDirectory: true)

    static func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A drag out of a Files window that lands on one must not upload what it just copied out.
    static func contains(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        return url.resolvingSymlinksInPath().path.hasPrefix(rootPath)
    }

    /// Finder copies an item while its drop lands, so a folder whose copy has ended holds only a leftover.
    static func remove(_ folders: [URL]) {
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// At launch no drag can be running, so whatever is there was left by an earlier run, such as one that quit.
    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
