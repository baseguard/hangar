import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct AppUpdateTests {
    @Test func versionsCompareByNumberNotByText() throws {
        let older = try #require(AppVersion("1.9.0"))
        let newer = try #require(AppVersion("v1.10.0"))

        #expect(older < newer)
        #expect(newer.description == "1.10.0")
        #expect(AppVersion("0.0.0")?.isRelease == false)
        #expect(AppVersion("1.2") == nil)
        #expect(AppVersion("1.2.3-beta") == nil)
        #expect(AppVersion("dev") == nil)
    }

    @Test func theLatestReleaseIsReadWithItsDiskImageAndDigest() throws {
        let digest = String(repeating: "ab", count: 32)
        let json = """
            {"tag_name": "v1.2.0", "html_url": "https://github.com/baseguard/hangar/releases/tag/v1.2.0",
             "assets": [
               {"name": "notes.txt", "browser_download_url": "https://github.com/x/notes.txt"},
               {"name": "Hangar.dmg", "browser_download_url": "https://github.com/baseguard/hangar/releases/download/v1.2.0/Hangar.dmg",
                "digest": "sha256:\(digest)"}
             ]}
            """

        let release = try AppRelease.decode(Data(json.utf8))

        #expect(release.version == AppVersion("1.2.0"))
        #expect(release.diskImage.lastPathComponent == "Hangar.dmg")
        #expect(release.diskImageDigest == digest)
        #expect(release.notesURL.absoluteString.hasSuffix("/tag/v1.2.0"))
    }

    /// The notes open in the browser, so a page off github.com shows the list of releases instead.
    @Test func releaseNotesOpenOnlyOnGitHub() throws {
        let json = #"""
            {"tag_name": "v1.2.0", "html_url": "file:///Applications/Calculator.app",
             "assets": [{"name": "Hangar.dmg", "browser_download_url": "https://github.com/baseguard/hangar/Hangar.dmg"}]}
            """#

        let release = try AppRelease.decode(Data(json.utf8))

        #expect(release.notesURL.absoluteString == "https://github.com/baseguard/hangar/releases")
    }

    @Test(arguments: [
        #"{"tag_name": "v1.2.0", "html_url": "https://github.com/r", "assets": []}"#,
        #"{"tag_name": "nightly", "html_url": "https://github.com/r", "assets": []}"#,
        #"{"tag_name": "v1.2.0", "html_url": "https://github.com/r", "assets": [{"name": "Hangar.dmg", "browser_download_url": "http://github.com/Hangar.dmg"}]}"#,
        #"{"message": "API rate limit exceeded"}"#,
    ])
    func aReleaseWithoutAnHTTPSDiskImageOrAVersionIsRefused(json: String) {
        #expect(throws: HangarError.self) { try AppRelease.decode(Data(json.utf8)) }
    }

    /// Anything not signed by Baseguard's Developer ID and notarized, like a build from source, is refused.
    @Test func anUnsignedAppIsNotInstalled() throws {
        let app = try makeApp(named: "Hangar.app", marker: "unsigned")

        #expect(throws: HangarError.self) { try AppSignature.checkApp(app) }
    }

    /// The image is checked before it is attached, so an unsigned one is never read by macOS's disk image code.
    @Test func anUnsignedDiskImageIsRefusedBeforeItIsAttached() throws {
        let image = HangarPaths.home.appendingPathComponent("Hangar.dmg")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(to: image)

        #expect(throws: HangarError.self) { try AppSignature.checkDiskImage(image) }
    }

    @Test func theUpdateTakesTheInstalledAppsPlaceAndTheOldOneGoes() throws {
        let installed = try makeApp(named: "Hangar.app", marker: "old")
        let staged = try makeApp(named: ".Hangar-update-1234.app", marker: "new")

        try AppUpdate.install(staged, replacing: installed)

        #expect(try marker(in: installed) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func anUpdateThatWasNeverInstalledIsRemovedAtTheNextLaunch() throws {
        let installed = try makeApp(named: "Hangar.app", marker: "installed")
        let leftover = try makeApp(named: ".Hangar-update-abcd.app", marker: "leftover")
        let other = try makeApp(named: "Other.app", marker: "other")

        AppUpdate.removeLeftovers(nextTo: installed)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    private func makeApp(named name: String, marker: String) throws -> URL {
        let app = HangarPaths.home.appendingPathComponent("Applications/\(name)", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "io.baseguard.hangar", "CFBundleShortVersionString": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return app
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }
}
