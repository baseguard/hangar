import Foundation
import HangarKit
import HangarSupport
import Testing

struct SharedFolderTests {
    @Test func parsesSharedFolderArguments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-share-test", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = try SharedFolder.parse(folder.path)
        #expect(plain.name == "hangar-share-test")
        #expect(!plain.readOnly)

        let named = try SharedFolder.parse("project:\(folder.path):ro")
        #expect(named.name == "project")
        #expect(named.readOnly)
        #expect(named.path == folder.standardizedFileURL.path)
        #expect(try !(SharedFolder.parse("project:\(folder.path):rw").readOnly))

        let colon = folder.appendingPathComponent("2024:25", isDirectory: true)
        try FileManager.default.createDirectory(at: colon, withIntermediateDirectories: true)
        #expect(try SharedFolder.parse(colon.path).path == colon.standardizedFileURL.path)
        #expect(try SharedFolder.parse(colon.path).name == "2024-25")
        #expect(try SharedFolder.parse("term:\(colon.path):ro").name == "term")
    }

    @Test(arguments: ["", "/definitely/not/here", "a:b:c:d", "bad/name:/tmp", ":/tmp"])
    func rejectsBadFolders(_ spec: String) {
        #expect(throws: (any Error).self) { try SharedFolder.parse(spec) }
    }

    @Test(.temporaryHangarHome)
    func hangarsLibraryIsSharedOnlyReadOnly() throws {
        let library = HangarPaths.home
        let inside = library.appendingPathComponent("vms")
        let outside = library.deletingLastPathComponent().appendingPathComponent("elsewhere")

        for path in [library, inside, library.deletingLastPathComponent()] {
            #expect(throws: (any Error).self) { try SharedFolder(name: "share", path: path.path).checkSafe() }
            try SharedFolder(name: "share", path: path.path, readOnly: true).checkSafe()
        }
        try SharedFolder(name: "share", path: outside.path).checkSafe()
    }
}
