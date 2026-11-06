import Foundation
import HangarSupport
import Testing

@testable import HangarKit

struct GuestFileBrowserTests {
    private func listing(_ json: String) throws -> GuestFolder {
        try GuestFileBrowser.folder(from: Data(json.utf8), vm: "deb")
    }

    private func entry(_ name: String, kind: String = "file", modified: Int = 1_730_812_345) -> String {
        #"{"name":"\#(name)","kind":"\#(kind)","link":false,"size":0,"modified":\#(modified)}"#
    }

    @Test func aListingFromTheAgentIsReadWithItsFoldersFirst() throws {
        let json = """
            {"path":"/home/admin","parent":"/home","truncated":false,"entries":[
            {"name":"notes.txt","kind":"file","link":false,"size":1234,"modified":1730812345},
            {"name":"Projects","kind":"folder","link":true,"size":0,"modified":0},
            {"name":"tty","kind":"other","link":false,"size":0,"modified":1730812345}]}
            """

        let folder = try listing(json)

        #expect(folder.path == "/home/admin")
        #expect(folder.parent == "/home")
        #expect(!folder.isTruncated)
        #expect(folder.entries.map(\.name) == ["Projects", "notes.txt", "tty"])
        let projects = try #require(folder.entries.first)
        #expect(projects.kind == .folder && projects.isLink && projects.modified == nil)
        let notes = try #require(folder.entries.first { $0.name == "notes.txt" })
        #expect(notes.size == 1234)
        #expect(notes.modified == Date(timeIntervalSince1970: 1_730_812_345))
    }

    @Test func aTopFolderHasNoParentAndATruncatedListingSaysSo() throws {
        let json = #"{"path":"C:\\","parent":null,"truncated":true,"entries":[]}"#

        let folder = try listing(json)

        #expect(folder.path == #"C:\"#)
        #expect(folder.parent == nil)
        #expect(folder.isTruncated)
    }

    @Test func aListingThatIsNotTheContractIsRefused() {
        let unknownKind = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(entry("x", kind: "pipe"))]}"#

        #expect(throws: HangarError.self) { try listing(unknownKind) }
        #expect(throws: HangarError.self) { try listing("not json") }
    }

    @Test func namesThisMacCantTellApartKeepOnlyTheFirst() throws {
        let composed = entry("caf\u{e9}", modified: 1)
        let decomposed = entry("cafe\u{301}", modified: 2)
        let entries = [composed, decomposed, entry("a"), entry("a", kind: "folder")].joined(separator: ",")
        let json = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(entries)]}"#

        let folder = try listing(json)

        #expect(folder.entries.count == 2)
        let cafe = try #require(folder.entries.first { $0.name == "caf\u{e9}" })
        #expect(cafe.modified == Date(timeIntervalSince1970: 1))
        #expect(folder.entries.first { $0.name == "a" }?.kind == .file)
    }

    /// Report.pdf lands as "Report 3.pdf" on a volume that ignores case and as itself on one that doesn't; either way
    /// nothing already there changes.
    @Test func aDownloadNeverReplacesAnItemAlreadyThere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-download-\(UUID().uuidString)")
        let firstCopy = try stagedFile("report.pdf", holding: "first", in: folder.appendingPathComponent("1"))
        let secondCopy = try stagedFile("Report.pdf", holding: "second", in: folder.appendingPathComponent("2"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let mine = folder.appendingPathComponent("report.pdf")
        try Data("mine".utf8).write(to: mine)

        let first = try GuestFileBrowser.moveToFreeName(firstCopy, into: folder)
        let second = try GuestFileBrowser.moveToFreeName(secondCopy, into: folder)

        #expect(first.lastPathComponent == "report 2.pdf")
        #expect(try Data(contentsOf: mine) == Data("mine".utf8))
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test func aDownloadsStagingFolderStaysWithinAFileNamesLength() {
        let long = String(repeating: "é", count: 200)

        let staging = GuestFileBrowser.stagingName(for: long, id: "1a2b3c4d")

        #expect(GuestFileBrowser.stagingName(for: "report.pdf", id: "1a2b3c4d") == "report.pdf (downloading 1a2b3c4d)")
        #expect(staging.utf8.count <= Int(NAME_MAX))
        #expect(staging.hasSuffix(" (downloading 1a2b3c4d)"))
    }

    private func stagedFile(_ name: String, holding text: String, in staging: URL) throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = staging.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func namesSortLikeFinderWithFoldersFirst() throws {
        let entries = ["file10", "file2", "b", "A"].map { entry($0) } + [entry("zfolder", kind: "folder")]
        let json = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(entries.joined(separator: ","))]}"#

        let folder = try listing(json)

        #expect(folder.entries.map(\.name) == ["zfolder", "A", "b", "file2", "file10"])
    }

    @Test func hugeSizesFromTheGuestDontOverflowTheDownloadsTotal() throws {
        let huge = #"{"name":"a","kind":"file","link":false,"size":18446744073709551615,"modified":0}"#
        let other = huge.replacingOccurrences(of: #""a""#, with: #""b""#)
        let json = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(huge),\#(other)]}"#
        let withFolder = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(entry("f", kind: "folder"))]}"#

        let total = GuestFileBrowser.downloadSize(of: try listing(json).entries)

        #expect(total == 2 * CopyExtractor.largestCopy)
        #expect(GuestFileBrowser.downloadSize(of: try listing(withFolder).entries) == 0)
    }

    @Test func aNameJoinsAFolderWithTheGuestsOwnSeparator() {
        #expect(GuestFileBrowser.path(of: "etc", in: "/", os: .linux) == "/etc")
        #expect(GuestFileBrowser.path(of: "notes.txt", in: "/home/dev", os: .macOS) == "/home/dev/notes.txt")
        #expect(GuestFileBrowser.path(of: "Users", in: #"C:\"#, os: .windows) == #"C:\Users"#)
        #expect(GuestFileBrowser.path(of: "dev", in: #"C:\Users"#, os: .windows) == #"C:\Users\dev"#)
    }

    @Test func enclosingFoldersRunFromTheTopDownInTheGuestsOwnForm() {
        #expect(GuestFileBrowser.enclosingFolders(of: "/home/dev", os: .linux) == ["/", "/home", "/home/dev"])
        #expect(GuestFileBrowser.enclosingFolders(of: "/", os: .macOS) == ["/"])
        #expect(
            GuestFileBrowser.enclosingFolders(of: #"C:\Users\dev"#, os: .windows) == [
                #"C:\"#, #"C:\Users"#, #"C:\Users\dev"#,
            ])
        #expect(GuestFileBrowser.enclosingFolders(of: #"C:\"#, os: .windows) == [#"C:\"#])
    }

    @Test func aFolderIsNamedByItsLastNameAndATopFolderByItself() {
        #expect(GuestFileBrowser.folderName(of: "/home/dev", os: .linux) == "dev")
        #expect(GuestFileBrowser.folderName(of: "/", os: .linux) == "/")
        #expect(GuestFileBrowser.folderName(of: #"C:\Users\dev"#, os: .windows) == "dev")
        #expect(GuestFileBrowser.folderName(of: #"C:\"#, os: .windows) == "C:")
    }

    @Test func goToFolderReadsATildeAsTheHomeFolder() {
        #expect(GuestFileBrowser.pathToList(typed: "  ") == nil)
        #expect(GuestFileBrowser.pathToList(typed: "~") == nil)
        #expect(GuestFileBrowser.pathToList(typed: "~/Projects") == "Projects")
        #expect(GuestFileBrowser.pathToList(typed: #"~\Desktop"#) == "Desktop")
        #expect(GuestFileBrowser.pathToList(typed: " /etc ") == "/etc")
    }

    @Test func aGuestNameThatCouldLeaveTheDownloadFolderIsRefused() throws {
        let names = ["..", ".", "", "a/b", "../../etc", "nul\u{0}x"]
        let json = names.map { entry($0.replacingOccurrences(of: "\u{0}", with: #"\u0000"#)) }
        let listed = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(json.joined(separator: ","))]}"#
        let folder = try listing(listed)
        let plain = try listing(#"{"path":"/","parent":null,"truncated":false,"entries":[\#(entry("ok.txt"))]}"#)

        for file in folder.entries {
            #expect(throws: HangarError.self) { try GuestFileBrowser.localName(of: file) }
        }
        #expect(try GuestFileBrowser.localName(of: try #require(plain.entries.first)) == "ok.txt")
    }

    @Test func theAgentsSentenceIsShownWithoutItsPrefix() {
        let reason = GuestFileBrowser.guestSentence(
            Data("hangar-agent: Could not list /root: Permission denied.\n".utf8), vm: "deb")

        #expect(reason?.message == "Could not list /root: Permission denied.")
        #expect(GuestFileBrowser.guestSentence(Data(), vm: "deb") == nil)
    }

    @Test func aLossyNameIsReadAndNeverDownloaded() throws {
        let lossy = #"{"name":"caf\#u{FFFD}","kind":"file","link":false,"size":0,"modified":0,"lossy":true}"#
        let json = #"{"path":"/","parent":null,"truncated":false,"entries":[\#(lossy),\#(entry("plain"))]}"#

        let folder = try listing(json)

        let lossyFile = try #require(folder.entries.first { $0.isLossy })
        #expect(lossyFile.name == "caf\u{FFFD}")
        #expect(folder.entries.first { $0.name == "plain" }?.isLossy == false)
        #expect(throws: HangarError.self) { try GuestFileBrowser.localName(of: lossyFile) }
    }

    @Test func aDownloadWithARefusedNameWritesNothing() async throws {
        let entries = [entry("one.txt"), entry("two.txt"), entry("..")].joined(separator: ",")
        let folder = try listing(#"{"path":"/","parent":null,"truncated":false,"entries":[\#(entries)]}"#)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let vm = VMBundle(url: URL(filePath: "/tmp/hangar-no-such-vm", directoryHint: .isDirectory))

        let error = await #expect(throws: HangarError.self) {
            try await GuestFileBrowser.download(
                folder.entries, from: folder, os: .linux, into: destination, in: vm, progress: { _, _ in })
        }

        #expect(error?.message == "“..” can't be a file name on this Mac.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func aFailedAgentCommandShowsTheGuestsSentenceButAMacFailureStaysAsItIs() {
        let vm = VMBundle(url: URL(filePath: "/tmp/deb", directoryHint: .isDirectory))

        let agentFailure = #expect(throws: HangarError.self) {
            try GuestFileBrowser.withGuestReason(in: vm, forAnyFailure: false) { errors in
                errors(Data("hangar-agent: No space left on the disk.\n".utf8))
                throw GuestCopy.CopyFailed(vm: "deb")
            }
        }
        let macFailure = #expect(throws: HangarError.self) {
            try GuestFileBrowser.withGuestReason(in: vm, forAnyFailure: false) { errors in
                errors(Data("hangar-agent: The archive ended early.\n".utf8))
                throw HangarError("Could not read notes.txt.")
            }
        }

        #expect(agentFailure?.message == "No space left on the disk.")
        #expect(macFailure?.message == "Could not read notes.txt.")
    }
}
