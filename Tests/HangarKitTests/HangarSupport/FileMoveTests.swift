import Darwin
import Foundation
import HangarSupport
import Testing

/// The volume here has an exclusive rename; these make it fail the way exFAT does, so the claim-then-rename path runs.
struct FileMoveTests {
    private static func exFATRename(_ from: String, _ to: String) -> Int32 {
        errno = ENOTSUP
        return -1
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func withoutAnExclusiveRenameAFileMovesToAFreeName() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = folder.appendingPathComponent("item.tar")
        try Data("new".utf8).write(to: item)
        let target = folder.appendingPathComponent("image.tar")

        let isMoved = try FileMove.withoutReplacing(item, to: target, exclusiveRename: Self.exFATRename)

        #expect(isMoved)
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }

    @Test func withoutAnExclusiveRenameATakenNameIsLeftAlone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = folder.appendingPathComponent("item.tar")
        try Data("new".utf8).write(to: item)
        let target = folder.appendingPathComponent("image.tar")
        try Data("mine".utf8).write(to: target)

        let isMoved = try FileMove.withoutReplacing(item, to: target, exclusiveRename: Self.exFATRename)

        #expect(!isMoved)
        #expect(try Data(contentsOf: target) == Data("mine".utf8))
        #expect(try Data(contentsOf: item) == Data("new".utf8))
    }

    @Test func withoutAnExclusiveRenameAFolderMovesWithWhatItHolds() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = folder.appendingPathComponent("staging/Projects")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: item.appendingPathComponent("notes.txt"))
        let target = folder.appendingPathComponent("Projects")

        let isMoved = try FileMove.withoutReplacing(item, to: target, exclusiveRename: Self.exFATRename)

        #expect(isMoved)
        #expect(try Data(contentsOf: target.appendingPathComponent("notes.txt")) == Data("notes".utf8))
    }

    @Test func aTakenNameIsLeftAloneByTheExclusiveRename() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = folder.appendingPathComponent("item.tar")
        try Data("new".utf8).write(to: item)
        let target = folder.appendingPathComponent("image.tar")
        try Data("mine".utf8).write(to: target)

        let isMoved = try FileMove.withoutReplacing(item, to: target)

        #expect(!isMoved)
        #expect(try Data(contentsOf: target) == Data("mine".utf8))
    }
}
