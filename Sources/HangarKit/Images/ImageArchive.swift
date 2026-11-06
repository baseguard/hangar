import CryptoKit
import Darwin
import Foundation
import HangarDisks
import HangarSupport
import System

final class ImageArchive: BlobSource {
    private struct Entry {
        let offset: Int64
        let size: Int64
    }

    let manifestDigest: String
    private let name: String
    private let fd: Int32
    private let entries: [String: Entry]

    private init(name: String, fd: Int32, entries: [String: Entry], manifestDigest: String) {
        self.name = name
        self.fd = fd
        self.entries = entries
        self.manifestDigest = manifestDigest
    }

    /// Reads every entry header up front, so a malformed file is refused before any of it is used.
    static func open(_ url: URL) throws -> ImageArchive {
        let name = url.lastPathComponent
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(url.path)") }
        do {
            let headers = try Self.entries(in: fd, name: name)
            let digest = try Self.manifestDigest(in: fd, entries: headers, name: name)
            return ImageArchive(name: name, fd: fd, entries: headers, manifestDigest: digest)
        } catch {
            close(fd)
            throw error
        }
    }

    deinit {
        close(fd)
    }

    func manifest(digest: String) async throws -> Data {
        guard digest == manifestDigest else { throw HangarError("\(name) doesn't hold the image \(digest).") }
        return try blob(digest, limit: VMImage.maximumManifest)
    }

    func blob(_ digest: String, limit: Int) throws -> Data {
        let entry = try self.entry(for: digest)
        guard entry.size <= Int64(limit) else {
            throw HangarError("\(name) holds a part that is larger than Hangar reads.")
        }

        let data = try Self.read(fd, at: entry.offset, count: Int(entry.size), from: name)
        guard SHA256.hash(data: data).ociDigest == digest else { throw HangarError("\(name) is damaged (\(digest)).") }
        return data
    }

    func streamBlob(
        _ digest: String, from start: Int64, begin: @escaping @Sendable (BlobStart) throws -> Void,
        consume: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let entry = try self.entry(for: digest)
        guard (0...entry.size).contains(start) else { throw HangarError("\(name) holds a shorter part than expected.") }
        try begin(start == 0 ? .whole : .partial(start: start, total: entry.size))
        var done = start
        while done < entry.size {
            try Task.checkCancellation()
            let count = Int(min(entry.size - done, 1 << 20))
            try consume(try Self.read(fd, at: entry.offset + done, count: count, from: name))
            done += Int64(count)
        }
    }

    private func entry(for digest: String) throws -> Entry {
        guard Digests.isValid(digest), let entry = entries[OCILayout.blobPath(digest)] else {
            throw HangarError("\(name) is missing a part of its image (\(digest)).")
        }
        return entry
    }

    private static func entries(in fd: Int32, name: String) throws -> [String: Entry] {
        func bad(_ reason: String) -> HangarError {
            HangarError("\(name) isn't an image file Hangar can read: \(reason).")
        }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw bad("it isn't a regular file") }

        let length = Int64(info.st_size)
        var entries: [String: Entry] = [:]
        var offset: Int64 = 0
        var headers = 0

        while true {
            guard offset + Int64(Tar.blockSize) <= length else { throw bad("it ends in the middle") }
            let header = try read(fd, at: offset, count: Tar.blockSize, from: name)
            if header.allSatisfy({ $0 == 0 }) { return entries }
            headers += 1
            guard headers <= VMImage.maximumLayers + 6 else { throw bad("it has too many entries") }
            let (path, size, isFile) = try parse(header, bad: bad)
            let start = offset + Int64(Tar.blockSize)
            guard size <= length - start else { throw bad("\(path) runs past the end of the file") }
            if isFile { entries[path] = Entry(offset: start, size: size) }
            offset = start + size + Tar.padding(after: size)
        }
    }

    /// Only regular files count: blobs are looked up by their exact names and checked against their digests, and
    /// nothing is ever unpacked, so other entries are passed over.
    private static func parse(_ header: Data, bad: (String) -> HangarError) throws -> (
        path: String, size: Int64, isFile: Bool
    ) {
        let bytes = [UInt8](header)
        func text(_ range: Range<Int>) throws -> String {
            let field = bytes[range].prefix { $0 != 0 }
            guard let value = String(bytes: field, encoding: .utf8) else { throw bad("an entry name isn't UTF-8") }
            return value
        }

        func number(_ range: Range<Int>) throws -> Int64 {
            let digits = try text(range).trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !digits.isEmpty, digits.count <= 11, let value = Int64(digits, radix: 8), value >= 0 else {
                throw bad("an entry has a size Hangar can't read")
            }
            return value
        }
        // A size with its high bit set is in tar's binary form, which only a huge entry needs.
        guard bytes[Tar.sizeField.lowerBound] & 0x80 == 0 else {
            throw bad("it holds an entry larger than Hangar reads")
        }
        let stored = try number(Tar.checksumField)
        guard stored == Int64(Tar.checksum(of: bytes)) else { throw bad("an entry header is damaged") }
        let magic = Array(bytes[Tar.magicField.lowerBound..<Tar.versionField.upperBound])
        guard magic == Array("ustar\u{0}00".utf8) || magic == Array("ustar  \u{0}".utf8) else {
            throw bad("it isn't a tar file")
        }

        let type = bytes[Tar.typeField]
        let isFile = type == UInt8(ascii: "0") || type == 0
        let prefix = try text(Tar.prefixField)
        var path = (prefix.isEmpty ? "" : prefix + "/") + (try text(Tar.nameField))
        while path.hasPrefix("./") { path.removeFirst(2) }
        return (path, try number(Tar.sizeField), isFile)
    }

    private static func manifestDigest(in fd: Int32, entries: [String: Entry], name: String) throws -> String {
        func bad(_ reason: String) -> HangarError {
            HangarError("\(name) isn't an image file Hangar can read: \(reason).")
        }
        guard let layout = entries["oci-layout"], layout.size <= 4096,
            let version = try? JSONDecoder().decode(
                [String: String].self, from: read(fd, at: layout.offset, count: Int(layout.size), from: name)),
            version["imageLayoutVersion"] == "1.0.0"
        else { throw bad("it has no OCI image layout") }
        guard let index = entries["index.json"], index.size <= 65_536,
            let decoded = try? JSONDecoder().decode(
                OCILayout.Index.self, from: read(fd, at: index.offset, count: Int(index.size), from: name))
        else {
            throw bad("it has no readable index.json")
        }
        guard decoded.manifests.count == 1, let manifest = decoded.manifests.first,
            manifest.mediaType == RegistryClient.manifestType,
            Digests.isValid(manifest.digest), (1...Int64(VMImage.maximumManifest)).contains(manifest.size),
            entries[OCILayout.blobPath(manifest.digest)]?.size == manifest.size
        else {
            throw bad("its index.json must name exactly one image")
        }

        return manifest.digest
    }

    static func read(_ fd: Int32, at offset: Int64, count: Int, from name: String) throws -> Data {
        var data = Data(count: count)
        let done: Int
        do {
            done = try data.withUnsafeMutableBytes { try FileDescriptor(rawValue: fd).readFully(into: $0, at: offset) }
        } catch let error as Errno {
            throw HangarError(errno: error.rawValue, "Could not read \(name)")
        }
        guard done == count else { throw HangarError("\(name) ended before Hangar read it all.") }
        return data
    }
}
