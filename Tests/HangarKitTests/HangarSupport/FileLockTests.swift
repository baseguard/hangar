import Foundation
import HangarSupport
import Testing

struct FileLockTests {
    @Test func aLockThatCannotBeOpenedSaysWhichFileAndWhy() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hangar-missing-\(UUID().uuidString)")
            .appendingPathComponent("vm.lock")
        let lock = FileLock(url: url)

        let failure = #expect(throws: HangarError.self) { try lock.tryLock(.exclusive) }

        #expect(failure?.message == "Could not open \(url.path): No such file or directory.")
    }

    @Test func onlyAHeldLockIsWrittenAndItsWholeContentReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = FileLock(url: url)

        #expect(throws: HangarError.self) { try lock.write(Data("early".utf8)) }
        #expect(try lock.tryLock(.exclusive))
        try lock.write(Data("a longer first line".utf8))
        try lock.write(Data("short".utf8))

        #expect(try String(contentsOf: url, encoding: .utf8) == "short")
        lock.unlock()
    }

    @Test func aLockWhoseFileWasDeletedOrReplacedNoLongerGuardsItsPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileLock(url: url)
        let second = FileLock(url: url)
        #expect(try first.tryLock(.exclusive))

        let isHeldAtFirst = first.isStillAtItsPath
        try FileManager.default.removeItem(at: url)
        let isHeldAfterDeletion = first.isStillAtItsPath
        let hasSecondLocked = try second.tryLock(.exclusive)
        let isHeldAfterReplacement = first.isStillAtItsPath

        #expect(isHeldAtFirst)
        #expect(!isHeldAfterDeletion)
        #expect(hasSecondLocked && second.isStillAtItsPath)
        #expect(!isHeldAfterReplacement)
    }

    @Test func exclusiveLockBlocksOthersUntilReleased() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileLock(url: url)
        let second = FileLock(url: url)

        #expect(try first.tryLock(.exclusive))
        #expect(FileLock.isHeld(url))
        #expect(try !second.tryLock(.exclusive))

        first.unlock()

        #expect(!FileLock.isHeld(url))
        #expect(try second.tryLock(.exclusive))
        second.unlock()
    }

    @Test func sharedLocksCoexist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileLock(url: url)
        let second = FileLock(url: url)

        #expect(try first.tryLock(.shared))
        #expect(try second.tryLock(.shared))
        #expect(try !FileLock(url: url).tryLock(.exclusive))
    }

    @Test func fileLocksDoNotCreateFolders() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-gone-\(UUID().uuidString)/x.lock")

        #expect(throws: (any Error).self) { try FileLock(url: missing).tryLock(.exclusive) }
        #expect(!(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path)))
    }
}
