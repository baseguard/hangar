import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct ImageBuilderTests {
    @Test func theFirstStartJobRunsTheScriptOnceAsRoot() throws {
        let job = try #require(
            try PropertyListSerialization.propertyList(from: try ImageBuilder.job(), format: nil) as? [String: Any])

        #expect(job["Label"] as? String == "io.baseguard.hangar.first-start")
        #expect(
            job["ProgramArguments"] as? [String] == [
                "/Library/Application Support/Hangar/Hangar.app/Contents/Helpers/HangarCLI.app/Contents/MacOS/hangar",
                "image",
                "first-start",
            ])
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["KeepAlive"] == nil)
        #expect(job["UserName"] == nil)
    }

    @Test func imagesAreTaggedWithTheirVersionsAndTheirKind() {
        let macOS = ImageBuilder.MacOS(version: "27.0.1", build: "27A100")

        let base = ImageBuilder.tags(kind: .base, macOS: macOS, xcode: nil)
        let xcode = ImageBuilder.tags(kind: .xcode, macOS: macOS, xcode: "27.0")

        #expect(base == ["base-27.0.1", "base"])
        #expect(xcode == ["xcode-27.0.1-27.0", "xcode"])
    }

    @Test func writesIntoAnImageNeverFollowLinks() throws {
        let volume = HangarPaths.home.appendingPathComponent("volume", isDirectory: true)
        let elsewhere = HangarPaths.home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(
            at: volume.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: volume.appendingPathComponent("Library/LaunchDaemons"), withDestinationURL: elsewhere)
        let root = try GuestDirectory(path: volume.path)

        #expect(
            failureMessage { try root.write(Data("job".utf8), at: ImageBuilder.jobPath, mode: 0o644) }
                == "Could not open LaunchDaemons in the image: Not a directory.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)

        try FileManager.default.removeItem(at: volume.appendingPathComponent("Library/LaunchDaemons"))
        try FileManager.default.createDirectory(
            at: volume.appendingPathComponent("Library/LaunchDaemons"), withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: volume.appendingPathComponent("Library/LaunchDaemons/io.baseguard.hangar.first-start.plist"),
            withDestinationURL: target)

        #expect(
            failureMessage { try root.write(Data("job".utf8), at: ImageBuilder.jobPath, mode: 0o644) }
                == "Library/LaunchDaemons/io.baseguard.hangar.first-start.plist in the image is not a regular file.")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try root.exists(ImageBuilder.jobPath))
        #expect(try !root.exists(ImageBuilder.folder))
    }

    @Test func aLinkWhereAFolderShouldBeIsAnErrorNotAMissingItem() throws {
        let volume = HangarPaths.home.appendingPathComponent("volume", isDirectory: true)
        let elsewhere = HangarPaths.home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: volume.appendingPathComponent("Applications"), withDestinationURL: elsewhere)
        let root = try GuestDirectory(path: volume.path)

        let missing = try root.exists(["Users", "admin", ".ssh"])

        #expect(!missing)
        #expect(
            failureMessage { try root.exists(["Applications", "Xcode.app"]) }
                == "Could not open Applications in the image: Not a directory.")
    }
}
