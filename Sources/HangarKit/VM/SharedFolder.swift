import Foundation
import HangarSupport

package struct SharedFolder: Codable, Hashable, Identifiable, Sendable {
    package var name: String
    package var path: String
    package var readOnly: Bool

    package init(name: String, path: String, readOnly: Bool = false) {
        self.name = name
        self.path = path
        self.readOnly = readOnly
    }

    package var id: String { name }

    package static func isReserved(_ name: String) -> Bool {
        name.lowercased() == GuestTools.shareName.lowercased()
    }

    package static func parse(_ spec: String) throws -> SharedFolder {
        var text = spec
        var readOnly = false

        for suffix in [":ro", ":rw"] where text.hasSuffix(suffix) {
            readOnly = suffix == ":ro"
            text = String(text.dropLast(3))
        }

        var name: String?
        var path = text

        if !text.hasPrefix("/"), !text.hasPrefix("~"), !text.hasPrefix("."), let colon = text.firstIndex(of: ":") {
            name = String(text[..<colon])
            path = String(text[text.index(after: colon)...])
        }

        guard !path.isEmpty, name?.isEmpty != true else {
            throw HangarError(
                "'\(spec)' is not a folder to share; use [name:]path[:ro], e.g. project:~/src/project:ro.")
        }

        return try make(path: path, name: name, readOnly: readOnly)
    }

    package static func make(path: String, name: String?, readOnly: Bool) throws -> SharedFolder {
        let url = URL(userPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HangarError("Not a folder: \(url.path)")
        }

        let folderName = name ?? defaultName(for: url)
        guard isValidName(folderName) else {
            throw HangarError("'\(folderName)' can't name a shared folder; give it another name.")
        }

        let folder = SharedFolder(name: folderName, path: url.path, readOnly: readOnly)
        try folder.checkSafe()
        return folder
    }

    package static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._ -]{0,63}/) != nil && !isReserved(name)
    }

    static func defaultName(for url: URL) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._ -"))
        var name = String(
            url.lastPathComponent.unicodeScalars.map { $0.isASCII && allowed.contains($0) ? Character($0) : "-" }
                .prefix(64))
        while let first = name.first, first == "." || first == "-" || first == " " { name.removeFirst() }
        return name.isEmpty ? "share" : name
    }

    package func checkSafe() throws {
        guard !readOnly else { return }
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let library = HangarPaths.home.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard library.starts(with: folder) || folder.starts(with: library) else { return }
        throw HangarError(
            "Sharing \(path) would let the guest change Hangar's own files, its traffic rules among them (\(HangarPaths.home.path)). Share it read-only, or share a folder that doesn't contain Hangar's library."
        )
    }
}
