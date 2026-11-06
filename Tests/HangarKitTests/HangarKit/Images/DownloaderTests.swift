import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct DownloaderTests {
    @Test func downloadsAreCheckedAndShared() async throws {
        let source = HangarPaths.home.appendingPathComponent("source.iso")
        let content = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try content.write(to: source)
        let digest = try Downloader.sha256(of: source)
        let file = HangarPaths.isoCache.appendingPathComponent("drivers.iso")

        #expect(
            await failureMessage {
                try await Downloader.cached(
                    source, as: file, digest: String(repeating: "0", count: 64), phase: "", progress: { _ in })
            } == "The download from \(source.absoluteString) does not match its known checksum.")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        async let first = Downloader.cached(source, as: file, digest: digest, phase: "", progress: { _ in })
        async let second = Downloader.cached(source, as: file, digest: digest, phase: "", progress: { _ in })
        #expect(try await [first, second] == [file, file])
        #expect(try Data(contentsOf: file) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: HangarPaths.isoCache.path) == ["drivers.iso"])
    }

    @Test(arguments: ["http://example.com/debian.iso", "HTTP://example.com/debian.iso"])
    func plainHTTPDownloadsAreRefused(source: String) async throws {
        let refusal = "Use an https:// address; Hangar doesn't download over plain http."
        #expect(await failureMessage { try await Downloader.localFile(for: source, progress: { _ in }) } == refusal)
        #expect(await failureMessage { try await MacInstaller.resolveIPSW(source, progress: { _ in }) } == refusal)
        #expect(try Downloader.remoteURL("https://example.com/debian.iso") != nil)
        #expect(try Downloader.remoteURL("~/Downloads/debian.iso") == nil)
    }

    @Test func redirectsToPlainHTTPAreRefused() async throws {
        let server = try await RedirectingServer()
        let file = HangarPaths.home.appendingPathComponent("debian.iso")

        try await Downloader.download(from: server.url.appending(path: "plain.iso"), to: file) { _, _ in }
        #expect(try String(contentsOf: file, encoding: .utf8) == "plain")
        try FileManager.default.removeItem(at: file)

        #expect(
            await failureMessage {
                try await Downloader.download(from: server.url.appending(path: "redirect"), to: file) { _, _ in }
            } == "Download refused: \(server.url.appending(path: "redirect").absoluteString) redirects to plain http.")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func checksumListsMatchOnlyTheExactName() {
        let sha256 = String(repeating: "ab", count: 32)
        let sha512 = String(repeating: "cd", count: 64)
        let ubuntu =
            "\(sha256) *ubuntu-26.04-server-cloudimg-arm64.tar.gz\n\(String(repeating: "0", count: 64)) *ubuntu-26.04-server-cloudimg-arm64.img\n"
        #expect(Downloader.checksum(of: "ubuntu-26.04-server-cloudimg-arm64.tar.gz", in: ubuntu) == sha256)
        let debian =
            "\(String(repeating: "1", count: 128))  debian-13-genericcloud-arm64.tar.xz.sig\n\(sha512)  debian-13-genericcloud-arm64.tar.xz\n"
        #expect(Downloader.checksum(of: "debian-13-genericcloud-arm64.tar.xz", in: debian) == sha512)
        #expect(Downloader.checksum(of: "arm64.tar.xz", in: debian) == nil)
        #expect(Downloader.checksum(of: "a.raw", in: "\(sha256.uppercased())  a.raw\n") == nil)
        #expect(Downloader.checksum(of: "a.raw", in: "abc123  a.raw\n") == nil)
    }
}
