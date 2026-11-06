import Darwin
import Foundation
import HangarDisks
import HangarSupport

/// Writes a file or folder on this Mac as `CopyArchive`'s stream for the VM. It never follows a link, so nothing outside
/// the item the user named goes into the copy; links and other special files are left out and counted.
struct CopyArchiveWriter {
    private let send: (Data) throws -> Void
    private(set) var skipped = 0

    /// `send` takes each piece of the stream, at most a frame's worth and never empty: an empty input frame ends the
    /// command's input, which an empty file or a size that needs no padding would otherwise send.
    init(send: @escaping (Data) throws -> Void) {
        self.send = { piece in
            guard !piece.isEmpty else { return }
            try send(piece)
        }
    }

    /// Writes `item` as a top-level entry called `name`; `finish` ends the archive after the last one.
    mutating func write(_ item: URL, as name: String) throws {
        guard let kind = Self.kind(of: item.path), kind == S_IFDIR || kind == S_IFREG else {
            throw HangarError("\(item.path) isn't a file or folder; links and special files aren't copied.")
        }
        try write(item, as: name, kind: kind)
    }

    func finish() throws {
        try send(CopyArchive.end)
    }

    private mutating func write(_ item: URL, as name: String, kind: mode_t) throws {
        switch kind {
        case S_IFDIR:
            try send(CopyArchive.blocks(for: .init(name: name, kind: .folder, size: 0, modified: Self.modified(item))))
            try writeContents(of: item, as: name)
        case S_IFREG:
            try writeFile(item, as: name)
        default:
            skipped += 1
        }
    }

    private mutating func writeContents(of folder: URL, as name: String) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for child in children {
            let url = folder.appendingPathComponent(child)
            guard let kind = Self.kind(of: url.path) else {
                skipped += 1
                continue
            }
            try write(url, as: name + "/" + child, kind: kind)
        }
    }

    /// Opened without following a link, so a file swapped for one after the walk saw it isn't read either.
    private func writeFile(_ file: URL, as name: String) throws {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw HangarError(errno: errno, "Could not read \(file.path)")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw HangarError("\(file.path) changed while it was copied.")
        }

        let isExecutable = info.st_mode & 0o111 != 0
        let header = CopyArchive.Header(
            name: name, kind: .file(isExecutable: isExecutable), size: UInt64(info.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
        try send(CopyArchive.blocks(for: header))
        try sendContents(of: descriptor, size: header.size, path: file.path)
        try send(Data(count: Int(Tar.padding(after: header.size))))
    }

    /// Exactly the size the header gave, so a file that grows or shrinks meanwhile can't break the stream.
    private func sendContents(of descriptor: Int32, size: UInt64, path: String) throws {
        var left = size
        var buffer = [UInt8](repeating: 0, count: ExecFrame.maximumPayload)
        while left > 0 {
            let wanted = Int(min(left, UInt64(buffer.count)))
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw HangarError("\(path) got shorter while it was copied.") }
            try send(Data(buffer[0..<count]))
            left -= UInt64(count)
        }
    }

    /// The item's type, without following a link; nil for a link or something that isn't there.
    private static func kind(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFLNK ? nil : kind
    }

    private static func modified(_ url: URL) -> Date {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .now }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}
