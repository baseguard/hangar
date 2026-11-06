import Foundation

/// A text log that a process appends to, one line at a time.
package enum LogFile {
    static let sizeLimit: UInt64 = 1 << 20
    /// So a huge log is never read whole for its last lines.
    private static let longestWindow: UInt64 = 8 << 20

    /// Where a log moves once it passes the size limit.
    package static func movedAside(_ log: URL) -> URL {
        log.appendingPathExtension("old")
    }

    /// Every start appends to the same log, so past the limit it moves to `<log>.old`, replacing the one before.
    package static func moveAsideIfLarge(_ log: URL) {
        guard size(of: log) > sizeLimit else { return }
        let old = movedAside(log)
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: log, to: old)
    }

    /// The last lines of a log.
    package struct Tail {
        package let lines: [Substring]
        /// Only then do they carry on from the log that was moved aside before it.
        package let reachesTheFirstLine: Bool
    }

    /// The last `count` lines of `log`, reaching back into the log it replaced when it has fewer.
    package static func recentLines(_ count: Int, of log: URL) -> [Substring] {
        let current = tail(count, of: log)
        guard current.reachesTheFirstLine else { return current.lines }

        let earlier = lastLines(count - current.lines.count, of: movedAside(log))
        return earlier + current.lines
    }

    /// The last `count` lines of `log`; none when it can't be read.
    package static func lastLines(_ count: Int, of log: URL) -> [Substring] {
        tail(count, of: log).lines
    }

    /// Lines are taken to be 1 KiB at most, so a huge log is never read whole for its last ones.
    package static func tail(_ count: Int, of log: URL) -> Tail {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: log) else {
            return Tail(lines: [], reachesTheFirstLine: true)
        }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let window = min(UInt64(count), longestWindow / 1024) * 1024
        let start = end > window ? end - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return Tail(lines: [], reachesTheFirstLine: true) }

        var lines = lines(in: data)
        // The window can start in the middle of a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Tail(lines: Array(lines.suffix(count)), reachesTheFirstLine: start == 0 && lines.count <= count)
    }

    /// The lines a process appends to a log from now on. A log that shrank was moved aside and
    /// started again, so it is read from its start.
    package final class Follower {
        private let log: URL
        private var offset: UInt64
        /// The start of a line whose newline hasn't been written yet.
        private var pending = Data()

        package init(log: URL) {
            self.log = log
            offset = LogFile.size(of: log)
        }

        /// The lines completed since the last call. Called in a loop that never ends, so each read's
        /// autoreleased data goes with its call.
        package func next() -> [Substring] {
            autoreleasepool { readNewLines() }
        }

        private func readNewLines() -> [Substring] {
            guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0

            if end < offset {
                offset = 0
                pending = Data()
            }

            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

            offset += UInt64(data.count)
            pending.append(data)
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }

            let complete = pending[...lastNewline]
            pending = Data(pending[pending.index(after: lastNewline)...])
            return LogFile.lines(in: complete)
        }
    }

    static func size(of file: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Blank lines stay; the empty piece after the last newline doesn't.
    private static func lines(in data: Data) -> [Substring] {
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
