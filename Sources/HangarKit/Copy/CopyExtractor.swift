import CoreServices
import Darwin
import Foundation
import HangarSupport

/// Writes a copy from the VM onto this Mac. The guest made the stream, so nothing in it is trusted: the Mac picks the
/// top-level name, every part of every name is checked, everything is created relative to the destination's folder
/// without following links, only files and folders are written, and only their contents, executable bit and date are
/// kept. Every file and folder is quarantined, like a download. A refusal stops the copy where it is; what was
/// written before it stays.
struct CopyExtractor {
    struct Summary: Equatable {
        var files = 0
        var skipped = 0
    }

    static let mostEntries = 100_000
    static let largestCopy: UInt64 = 64 << 30
    /// Room this Mac keeps for itself.
    static let spaceToKeep: UInt64 = 1 << 30

    private let parent: Int32
    private let parentURL: URL
    private let topName: String
    private let byteLimit: UInt64
    private var topInArchive: String?
    private var written: UInt64 = 0
    private var entries = 0
    private(set) var summary = Summary()

    /// Writes into `parent` as `name`; `parent` must already exist. The user named it, so a link on its way, like
    /// /tmp, is followed; nothing below it is.
    init(into parent: URL, as name: String) throws {
        let folder = parent.resolvingSymlinksInPath()
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw HangarError(errno: errno, "Could not open \(parent.path)")
        }
        self.parent = descriptor
        parentURL = folder
        topName = name
        byteLimit = Self.byteLimit(for: parent)
    }

    func close() {
        Darwin.close(parent)
    }

    /// Reads entries until the archive ends.
    mutating func extract(from reader: inout CopyArchiveReader) throws {
        while let item = try reader.next() {
            switch item {
            case .skipped:
                summary.skipped += 1
            case .entry(let header):
                do {
                    try write(header, from: &reader)
                } catch {
                    let name = CopyArchive.printable(header.name)
                    let kept = "\(summary.files) file\(summary.files == 1 ? "" : "s") written before it stay"
                    throw HangarError("The copy stopped at \(name): \(error.localizedDescription) \(kept).")
                }
            }
        }
    }

    private mutating func write(_ header: CopyArchive.Header, from reader: inout CopyArchiveReader) throws {
        entries += 1
        guard entries <= Self.mostEntries else { throw HangarError("It has more than \(Self.mostEntries) entries.") }
        // Not written + size: a size near the largest number from the guest would overflow.
        guard header.size <= byteLimit - written else {
            throw HangarError("It would take more than \(ByteSize.format(byteLimit)) of this Mac's disk.")
        }
        let parts = try localParts(of: header.name)
        let folder = try openFolder(for: parts.dropLast())
        defer { Darwin.close(folder) }

        switch header.kind {
        case .folder:
            try makeFolder(parts[parts.count - 1], in: folder)
            quarantine(parts.joined(separator: "/"))
        case .file(let isExecutable):
            try writeFile(parts[parts.count - 1], in: folder, header: header, isExecutable: isExecutable, from: &reader)
            written += header.size
            summary.files += 1
            quarantine(parts.joined(separator: "/"))
        }
    }

    /// The entry's name with its top-level part replaced by the one the Mac chose; every entry shares that top.
    private mutating func localParts(of name: String) throws -> [String] {
        var parts = try CopyArchive.components(of: name)
        let top = topInArchive ?? parts[0]
        guard parts[0] == top else { throw HangarError("It holds more than one top-level item.") }
        topInArchive = top
        parts[0] = topName
        return parts
    }

    /// Opens each folder on the way down without following links, making the ones that aren't there.
    private func openFolder(for parts: ArraySlice<String>) throws -> Int32 {
        var current = dup(parent)
        for part in parts {
            try makeFolder(part, in: current)
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            Darwin.close(current)
            guard next >= 0 else { throw HangarError("\(part) isn't a folder here.") }
            current = next
        }
        return current
    }

    /// An existing folder is only added to; anything else in its place stops the copy.
    private func makeFolder(_ name: String, in folder: Int32) throws {
        if mkdirat(folder, name, 0o755) == 0 { return }
        guard errno == EEXIST else { throw HangarError(String(cString: strerror(errno)) + ".") }
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw HangarError("Something that isn't a folder is already at \(name).")
        }
    }

    /// Truncates a file that is there, so nothing of the old one stays; a link in its place stops the copy.
    private func writeFile(
        _ name: String, in folder: Int32, header: CopyArchive.Header, isExecutable: Bool,
        from reader: inout CopyArchiveReader
    ) throws {
        let mode: mode_t = isExecutable ? 0o755 : 0o644
        let file = try openRegularFile(name, in: folder, mode: mode)
        defer { Darwin.close(file) }

        try reader.readData(of: header) { piece in try Self.writeAll(piece, to: file) }
        fchmod(file, mode)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(header.modified)]
        futimens(file, &times)
    }

    /// Truncated only once it is known to be a file: a FIFO, device or socket already at that name is refused, and
    /// O_NONBLOCK keeps a FIFO from blocking the open.
    private func openRegularFile(_ name: String, in folder: Int32, mode: mode_t) throws -> Int32 {
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY, mode)
        guard file >= 0 else { throw HangarError(String(cString: strerror(errno)) + ".") }

        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(file)
            throw HangarError("A special file has its name.")
        }
        guard ftruncate(file, 0) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(file)
            throw HangarError(reason + ".")
        }
        return file
    }

    /// Like a download, so Gatekeeper checks an app or a script from the VM before it first runs.
    private func quarantine(_ relativePath: String) {
        var url = parentURL.appendingPathComponent(relativePath)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Hangar",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? url.setResourceValues(values)
    }

    private static func writeAll(_ data: Data, to file: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HangarError(String(cString: strerror(errno)) + ".") }
                offset += count
            }
        }
    }

    private static func byteLimit(for folder: URL) -> UInt64 {
        let free =
            (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
        return min(largestCopy, free > spaceToKeep ? free - spaceToKeep : 0)
    }
}

extension timespec {
    fileprivate init(_ date: Date) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: 0)
    }
}
