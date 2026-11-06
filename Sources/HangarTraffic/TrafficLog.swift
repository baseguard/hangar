import Darwin
import Foundation
import HangarSupport

package enum TrafficLog {
    static let maximumSize: UInt64 = 16 << 20

    static let keptFiles = 3

    static func previousURL(of log: URL, _ index: Int = 1) -> URL {
        log.deletingPathExtension().appendingPathExtension("\(index)").appendingPathExtension("jsonl")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    package static func stamp(of log: URL) -> String {
        var info = stat()
        guard stat(log.path, &info) == 0 else { return "" }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)-\(info.st_ino)"
    }

    static func decode(_ lines: some Sequence<Substring>) -> [TrafficEvent] {
        lines.compactMap { try? JSON.decoder.decode(TrafficEvent.self, from: Data($0.utf8)) }
    }

    package static func recent(in log: URL, limit: Int) -> [TrafficEvent] {
        var tail = LogFile.tail(limit, of: log)
        var events = decode(tail.lines)

        for index in 1...keptFiles where events.count < limit && tail.reachesTheFirstLine {
            tail = LogFile.tail(limit - events.count, of: previousURL(of: log, index))
            events = decode(tail.lines) + events
        }
        return events
    }

    /// Copies the whole log, its kept older files first, into one JSON Lines file only the user can read, as the log is.
    package static func export(_ log: URL, to destination: URL) throws {
        let parts = (1...keptFiles).reversed().map { previousURL(of: log, $0) } + [log]
        let target = destination.resolvingSymlinksInPath()
        guard !parts.contains(where: { $0.resolvingSymlinksInPath() == target }) else {
            throw HangarError("Choose another file to export the traffic log to; this one is part of the log.")
        }

        // Opened before copying, so a rotation while it copies can't skip or repeat a file.
        let inputs = parts.compactMap { try? FileHandle(forReadingFrom: $0) }
        defer { for input in inputs { try? input.close() } }
        guard !inputs.isEmpty else { throw HangarError("No traffic has been recorded for this VM yet.") }

        let isCreated = FileManager.default.createFile(
            atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard isCreated else { throw HangarError("Could not create \(destination.path).") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for input in inputs {
            try copy(input, to: output)
        }
        try output.synchronize()
    }

    private static func copy(_ input: FileHandle, to output: FileHandle) throws {
        while let piece = try input.readPiece(upToCount: 1 << 20), !piece.isEmpty {
            try output.write(contentsOf: piece)
        }
    }

    package final class Writer {
        private let url: URL
        private let maximumSize: UInt64
        private var handle: FileHandle?
        private var size: UInt64 = 0
        private var failedWrites = 0

        package init(url: URL, maximumSize: UInt64 = TrafficLog.maximumSize) {
            self.url = url
            self.maximumSize = maximumSize
            open()
        }

        package func write(_ event: TrafficEvent) {
            guard var data = try? TrafficLog.encoder.encode(event) else {
                failedWrites += 1
                return
            }
            data.append(UInt8(ascii: "\n"))
            if size + UInt64(data.count) > maximumSize { rotate() }
            guard let handle, (try? handle.write(contentsOf: data)) != nil else {
                failedWrites += 1
                return
            }
            size += UInt64(data.count)
        }

        /// The entries lost since the last call, so the owner can say so now and then.
        package func takeFailedWrites() -> Int {
            defer { failedWrites = 0 }
            return failedWrites
        }

        package func close() {
            try? handle?.close()
            handle = nil
        }

        private func open() {
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                HangarLog.warning(HangarError(errno: errno, "Could not open \(url.path)").message)
                return
            }

            var info = stat()
            size = fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        private func rotate() {
            close()
            for index in stride(from: TrafficLog.keptFiles, to: 1, by: -1) {
                moveAside(TrafficLog.previousURL(of: url, index - 1), to: TrafficLog.previousURL(of: url, index))
            }
            moveAside(url, to: TrafficLog.previousURL(of: url))
            open()
        }

        /// A log that was never written is nothing to move; any other failure is noted, and the log keeps writing.
        private func moveAside(_ log: URL, to kept: URL) {
            guard rename(log.path, kept.path) != 0, errno != ENOENT else { return }
            HangarLog.warning(HangarError(errno: errno, "Could not rotate \(log.path)").message)
        }
    }

    package final class Follower {
        private let lines: LogFile.Follower

        package init(url: URL) {
            lines = LogFile.Follower(log: url)
        }

        package func next() -> [TrafficEvent] {
            TrafficLog.decode(lines.next())
        }
    }
}
