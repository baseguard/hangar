import Darwin
import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

struct CopyArchiveTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The archive of `item`, as the Mac sends it to the VM.
    private func archive(of item: URL) throws -> (Data, skipped: Int) {
        var data = Data()
        var writer = CopyArchiveWriter { data.append($0) }
        try writer.write(item, as: item.lastPathComponent)
        try writer.finish()
        return (data, writer.skipped)
    }

    /// Extracts `data` into `parent` as `name`, the way a copy from the VM is written.
    private func extract(_ data: Data, into parent: URL, as name: String) throws -> CopyExtractor.Summary {
        var pieces = stride(from: 0, to: data.count, by: 1000).map { data[$0..<min($0 + 1000, data.count)] }
        var reader = CopyArchiveReader { pieces.isEmpty ? nil : Data(pieces.removeFirst()) }
        var extractor = try CopyExtractor(into: parent, as: name)
        defer { extractor.close() }
        try extractor.extract(from: &reader)
        return extractor.summary
    }

    /// A header of any type, as a guest could send one.
    private func rawEntry(_ name: String, type: Character, mode: String = "0000644", body: Data = Data()) -> Data {
        var header = [UInt8](
            CopyArchive.blocks(for: .init(name: "x", kind: .file(isExecutable: false), size: 0, modified: .now)))
        header.replaceSubrange(0..<100, with: Array(name.utf8) + [UInt8](repeating: 0, count: 100 - name.utf8.count))
        header.replaceSubrange(100..<107, with: Array(mode.utf8))
        let size = String(body.count, radix: 8)
        header.replaceSubrange(124..<135, with: Array((String(repeating: "0", count: 11 - size.count) + size).utf8))
        header[156] = UInt8(String(type).utf8.first ?? 0)
        let checksum = String(Tar.checksum(of: header), radix: 8)
        header.replaceSubrange(
            148..<156, with: Array((String(repeating: "0", count: 6 - checksum.count) + checksum).utf8) + [0, 0x20])
        return Data(header) + body + Data(count: Tar.padding(after: body.count))
    }

    @Test func aFolderMakesTheRoundTripUnderTheNameTheMacPicks() throws {
        let source = try temporaryFolder().appendingPathComponent("project")
        let deep = source.appendingPathComponent(String(repeating: "long-folder-name-", count: 8))
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("readme.txt"))
        try Data("#!/bin/sh".utf8).write(to: deep.appendingPathComponent("run.sh"))
        chmod(deep.appendingPathComponent("run.sh").path, 0o755)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let target = try temporaryFolder()

        let (data, skipped) = try archive(of: source)
        let summary = try extract(data, into: target, as: "copy")

        let copy = target.appendingPathComponent("copy")
        #expect(skipped == 1)
        #expect(summary == CopyExtractor.Summary(files: 2, skipped: 0))
        #expect(try String(contentsOf: copy.appendingPathComponent("readme.txt"), encoding: .utf8) == "hello")
        let script = copy.appendingPathComponent(deep.lastPathComponent).appendingPathComponent("run.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("link").path))
        #expect(
            try copy.appendingPathComponent("readme.txt").resourceValues(forKeys: [.quarantinePropertiesKey])
                .quarantineProperties != nil)
        #expect(try copy.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
    }

    @Test(arguments: ["top/../escape", "/etc/passwd", "top/a\\b", "top//x", "top/./x", "top/bad\u{1b}[31m", "other"])
    func aNameThatCouldReachOutsideStopsTheCopy(name: String) throws {
        let target = try temporaryFolder()
        let data = rawEntry("top/", type: "5") + rawEntry(name, type: "0", body: Data("x".utf8)) + CopyArchive.end

        #expect(throws: (any Error).self) { try extract(data, into: target, as: "copy") }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("escape").path))
    }

    @Test func linksAndSpecialFilesFromTheVMAreSkippedAndSetuidIsDropped() throws {
        let target = try temporaryFolder()
        let data =
            rawEntry("top/", type: "5") + rawEntry("top/link", type: "2") + rawEntry("top/fifo", type: "6")
            + rawEntry("top/tool", type: "0", mode: "0004755", body: Data("x".utf8)) + CopyArchive.end

        let summary = try extract(data, into: target, as: "copy")

        let tool = target.appendingPathComponent("copy/tool")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: tool.path)[.posixPermissions] as? Int)
        #expect(summary == CopyExtractor.Summary(files: 1, skipped: 2))
        #expect(mode == 0o755)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("copy/link").path))
    }

    @Test func aLinkAlreadyOnThePathStopsTheCopyAndAFileIsReplacedWhole() throws {
        let target = try temporaryFolder()
        let outside = try temporaryFolder()
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("copy"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("copy/sub"), withDestinationURL: outside)
        try Data("a much longer old text".utf8).write(to: target.appendingPathComponent("copy/notes.txt"))
        let throughLink = rawEntry("top/", type: "5") + rawEntry("top/sub/x", type: "0", body: Data("x".utf8))
        let replacing = rawEntry("top/", type: "5") + rawEntry("top/notes.txt", type: "0", body: Data("new".utf8))

        #expect(throws: (any Error).self) { try extract(throughLink + CopyArchive.end, into: target, as: "copy") }
        _ = try extract(replacing + CopyArchive.end, into: target, as: "copy")

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try String(contentsOf: target.appendingPathComponent("copy/notes.txt"), encoding: .utf8) == "new")
    }

    @Test func aDamagedHeaderStopsTheCopy() throws {
        let target = try temporaryFolder()
        var data = rawEntry("top", type: "0", body: Data("x".utf8)) + CopyArchive.end
        data[150] ^= 0x01

        #expect(throws: (any Error).self) { try extract(data, into: target, as: "copy") }
    }

    @Test func anEmptyFileAndOneThatNeedsNoPaddingSendNoEmptyPiece() throws {
        let folder = try temporaryFolder().appendingPathComponent("top")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("empty"))
        try Data(count: 512).write(to: folder.appendingPathComponent("one-block"))
        var pieces: [Data] = []
        var writer = CopyArchiveWriter { pieces.append($0) }

        try writer.write(folder, as: "top")
        try writer.finish()

        #expect(!pieces.contains { $0.isEmpty })
        #expect(try extract(pieces.reduce(Data(), +), into: temporaryFolder(), as: "copy").files == 2)
    }

    @Test func aFIFOAtAFileNameStopsTheCopyWithoutBlocking() throws {
        let target = try temporaryFolder()
        mkfifo(target.appendingPathComponent("copy").path, 0o644)
        let data = rawEntry("top", type: "0", body: Data("x".utf8)) + CopyArchive.end

        #expect(throws: (any Error).self) { try extract(data, into: target, as: "copy") }
    }

    @Test func theAgentsMessagesReachTheTerminalWithoutControlCharacters() {
        let message = Data("copy /x/\u{1b}[31mred\u{7f}: refused\n\tnext\n".utf8)

        let cleaned = message.withoutControlCharacters

        #expect(String(decoding: cleaned, as: UTF8.self) == "copy /x/?[31mred?: refused\n\tnext\n")
    }

    @Test func aDestinationReachedThroughALinkIsUsed() throws {
        let real = try temporaryFolder()
        let link = try temporaryFolder().appendingPathComponent("tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let data = rawEntry("top", type: "0", body: Data("x".utf8)) + CopyArchive.end

        _ = try extract(data, into: link, as: "copy")

        #expect(try String(contentsOf: real.appendingPathComponent("copy"), encoding: .utf8) == "x")
    }

    @Test func anArchiveCutOffBetweenEntriesFails() throws {
        let target = try temporaryFolder()
        let cut = rawEntry("top/", type: "5") + rawEntry("top/a", type: "0", body: Data("x".utf8))

        #expect(throws: (any Error).self) { try extract(cut, into: target, as: "copy") }
    }

    @Test func aSizeNearTheLargestNumberIsRefusedNotOverflowed() throws {
        let target = try temporaryFolder()
        let record = Data("29 size=18446744073709551615\n".utf8)
        let pax = rawEntry("PaxHeader", type: "x", body: record)

        #expect(throws: (any Error).self) {
            try extract(pax + rawEntry("top", type: "0") + CopyArchive.end, into: target, as: "copy")
        }
        #expect(throws: (any Error).self) {
            try extract(pax + rawEntry("top", type: "g") + CopyArchive.end, into: target, as: "copy")
        }
    }
}
