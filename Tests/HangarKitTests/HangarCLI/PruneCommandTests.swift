import Foundation
import HangarSupport
import Testing

@Suite(.temporaryHangarHome)
struct PruneCommandTests {
    @Test func aDownloadThatCouldNotBeDeletedFailsTheCommand() throws {
        let iso = HangarPaths.cache.appendingPathComponent("iso")
        try FileManager.default.createDirectory(at: iso, withIntermediateDirectories: true)
        let inUse = iso.appendingPathComponent("0123456789ab-alpine.iso")
        let unused = iso.appendingPathComponent("0123456789ab-arch.iso")
        try Data(count: 10).write(to: inUse)
        try Data(count: 10).write(to: unused)
        let lock = FileLock(url: inUse.appendingPathExtension("lock"))
        #expect(try lock.tryLock(.exclusive))

        let result = try HangarCommand.run(["prune", "--older-than", "0"])

        #expect(result.status == 1)
        #expect(result.error.contains("Kept alpine.iso"))
        #expect(result.error.hasSuffix("Error: 1 download could not be deleted.\n"))
        #expect(!FileManager.default.fileExists(atPath: unused.path))
        // Holds the download's lock, and so its "in use" state, until the command has run.
        lock.unlock()
    }
}
