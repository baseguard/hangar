import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct ImageArchiveTests {
    private static func entry(
        _ name: String, _ data: Data = Data(), type: UInt8 = UInt8(ascii: "0"), declaredSize: Int? = nil,
        sizeField: String? = nil
    ) -> Data {
        var header = [UInt8](ImageArchiveWriter.header(name: name, size: declaredSize ?? data.count))
        header[156] = type
        if let sizeField {
            let padding = [UInt8](repeating: 0, count: 12 - sizeField.utf8.count)
            header.replaceSubrange(124..<136, with: Array(sizeField.utf8) + padding)
        }
        header.replaceSubrange(148..<156, with: Array("        ".utf8))
        let sum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        header.replaceSubrange(
            148..<155, with: Array((String(repeating: "0", count: 6 - sum.count) + sum + "\u{0}").utf8))
        return Data(header) + data + Data(count: (512 - data.count % 512) % 512)
    }

    private static let layout = entry("oci-layout", Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8))

    private static func index(_ digests: [String], size: Int) -> Data {
        let manifests = digests.map {
            #"{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\#($0)","size":\#(size)}"#
        }
        return entry(
            "index.json", Data(#"{"schemaVersion":2,"manifests":[\#(manifests.joined(separator: ","))]}"#.utf8))
    }

    private func open(_ parts: [Data], end: Bool = true) throws -> ImageArchive {
        let url = HangarPaths.home.appendingPathComponent("image.tar")
        try (parts.reduce(Data(), +) + (end ? Data(count: 1024) : Data())).write(to: url)
        return try ImageArchive.open(url)
    }

    @Test func aWellFormedArchiveOpens() async throws {
        let manifest = Data("{}".utf8)
        let digest = VMImage.digest(of: manifest)
        let blob = Self.entry("blobs/sha256/\(digest.dropFirst(7))", manifest)

        let archive = try open([
            Self.entry("./blobs/", type: UInt8(ascii: "5")), Self.layout, blob, Self.index([digest], size: 2),
        ])

        #expect(archive.manifestDigest == digest)
        #expect(try await archive.manifest(digest: digest) == manifest)
    }

    @Test func malformedArchivesAreRefused() async throws {
        let manifest = Data("{}".utf8)
        let digest = VMImage.digest(of: manifest)
        let blob = Self.entry("blobs/sha256/\(digest.dropFirst(7))", manifest)
        let index = Self.index([digest], size: 2)
        let other = VMImage.digest(of: Data("other".utf8))
        var damaged = blob
        damaged[148] = UInt8(ascii: "7")
        let tooLong = Self.entry("blobs/sha256/\(other.dropFirst(7))", Data(count: 10), declaredSize: 1 << 20)
        let negativeSize = Self.entry("oci-layout", sizeField: "-1")
        let bad: [(String, reason: String, [Data])] = [
            ("no layout", "it has no OCI image layout", [blob, index]),
            ("no index", "it has no readable index.json", [Self.layout, blob]),
            (
                "two images", "its index.json must name exactly one image",
                [
                    Self.layout, blob, Self.entry("blobs/sha256/\(other.dropFirst(7))", Data("other".utf8)),
                    Self.index([digest, other], size: 2),
                ]
            ),
            (
                "missing image", "its index.json must name exactly one image",
                [Self.layout, Self.index([digest], size: 2)]
            ),
            (
                "wrong size", "its index.json must name exactly one image",
                [Self.layout, blob, Self.index([digest], size: 3)]
            ),
            ("damaged header", "an entry header is damaged", [Self.layout, damaged, index]),
            ("negative size", "an entry has a size Hangar can't read", [negativeSize, blob, index]),
            (
                "past the end", "blobs/sha256/\(other.dropFirst(7)) runs past the end of the file",
                [Self.layout, blob, index, tooLong]
            ),
        ]

        for (label, reason, parts) in bad {
            #expect(
                failureMessage { try open(parts) } == "image.tar isn't an image file Hangar can read: \(reason).",
                "\(label)")
        }
        #expect(
            failureMessage { try open([Self.layout, blob, index], end: false) }
                == "image.tar isn't an image file Hangar can read: it ends in the middle.")

        let forged = Self.entry("blobs/sha256/\(digest.dropFirst(7))", Data("[]".utf8))
        let archive = try open([Self.layout, forged, index])
        #expect(
            await failureMessage { try await archive.manifest(digest: digest) } == "image.tar is damaged (\(digest)).")
        #expect(
            await failureMessage { try await archive.manifest(digest: other) }
                == "image.tar doesn't hold the image \(other).")
    }

    @Test func imageFilesComeBackByteForByte() async throws {
        let bundle = try TestVM.make(.linux)
        try bundle.updateConfig { $0.sshUser = "dev" }
        let disk = try Data(contentsOf: bundle.diskURL)
        let file = HangarPaths.home.appendingPathComponent("ci-linux.tar")

        _ = try await VMImage.export(bundle, to: file) { _ in }

        #expect(
            await failureMessage { try await VMImage.export(bundle, to: file) { _ in } }
                == "\(file.path) already exists.")
        // Each export stamps its time to the second, so only the last one's digest names the image on disk.
        let digest = try await VMImage.export(bundle, to: file, replacing: true) { _ in }
        #expect(
            await failureMessage {
                try await VMImage.export(bundle, to: HangarPaths.home.appendingPathComponent("ci-linux.img")) { _ in }
            } == "An image file ends in .tar.")

        let settings = try await VMImage.inspect(imageFile: file)
        #expect(settings.os == .linux)
        #expect(settings.diskSize == bundle.diskSize)

        let copy = try await VMImage.createVM(
            name: "copy", imageFile: file, os: .linux, options: CreateOptions(diskSize: 1 << 20)
        ) { _ in }
        #expect(try Data(contentsOf: copy.diskURL) == disk)
        #expect(try copy.loadConfig().image == nil)
        #expect(try copy.loadConfig().sshUser == "dev")
        let record = try #require(VMImage.record(in: VMImage.cache.appendingPathComponent(String(digest.dropFirst(7)))))
        #expect(record.name == "ci-linux.tar")

        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "wrong", imageFile: file, os: .windows, options: CreateOptions(diskSize: 1 << 20)
                ) { _ in }
            } == "This is a Linux image, not Windows.")

        var tampered = try Data(contentsOf: file)
        try? FileManager.default.removeItem(at: VMImage.cache)
        let manifest = try JSONDecoder().decode(
            VMImage.Manifest.self, from: try await ImageArchive.open(file).manifest(digest: digest))
        let part = try #require(manifest.layers.last)
        let header = try #require(tampered.range(of: Data("blobs/sha256/\(part.digest.dropFirst(7))".utf8)))
        tampered[header.lowerBound + 512 + 10] ^= 0xff
        let damaged = HangarPaths.home.appendingPathComponent("damaged.tar")
        try tampered.write(to: damaged)

        #expect(
            await failureMessage {
                try await VMImage.createVM(
                    name: "damaged", imageFile: damaged, os: .linux, options: CreateOptions(diskSize: 1 << 20)
                ) { _ in }
            } == "A disk part didn't match its digest (\(part.digest)).")

        try bundle.updateConfig { $0.firstStartedAt = nil }
        let never = HangarPaths.home.appendingPathComponent("never.tar")
        #expect(
            await failureMessage { try await VMImage.export(bundle, to: never) { _ in } }
                == "'\(bundle.name)' hasn't started yet, so its accounts aren't set up on the disk; start it once, then push it."
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: HangarPaths.home.path).filter {
            $0.hasPrefix("never.tar")
        }
        #expect(leftovers.isEmpty)
        let kept = try Data(contentsOf: file)
        #expect(await failureMessage { try await VMImage.export(bundle, to: file, replacing: true) { _ in } } != nil)
        #expect(try Data(contentsOf: file) == kept)

        #expect(VMImage.isImageFile("ghcr.io/acme/ci:v1.tar") && !VMImage.isImageFile("ghcr.io/acme/ci:v1"))
    }
}
