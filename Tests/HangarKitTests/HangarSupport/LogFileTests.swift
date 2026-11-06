import Foundation
import Testing

@testable import HangarSupport

struct LogFileTests {
    @Test func theLastLinesComeFromTheEndOnly() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let text = (1...50_000).map { "line \($0)" }.joined(separator: "\n")
        try text.write(to: log, atomically: true, encoding: .utf8)

        let lastTwo = LogFile.lastLines(2, of: log)
        let missing = LogFile.lastLines(2, of: log.appendingPathExtension("missing"))

        #expect(lastTwo == ["line 49999", "line 50000"])
        #expect(missing.isEmpty)
    }

    @Test func blankLinesStayAndTheFinalNewlineIsNoLine() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        try Data("a\n\nb\n".utf8).write(to: log)

        let lines = LogFile.lastLines(3, of: log)

        #expect(lines == ["a", "", "b"])
    }

    @Test func recentLinesReachBackIntoTheLogMovedAside() throws {
        let log = temporaryLog()
        let old = LogFile.movedAside(log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: old)
        }
        try Data("a\nb\n".utf8).write(to: old)
        try Data("c\n".utf8).write(to: log)

        let two = LogFile.recentLines(2, of: log)
        let all = LogFile.recentLines(10, of: log)

        #expect(two == ["b", "c"])
        #expect(all == ["a", "b", "c"])
    }

    @Test func aLogCutShortByTheWindowDoesNotReachBack() throws {
        let log = temporaryLog()
        let old = LogFile.movedAside(log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: old)
        }
        let longLine = String(repeating: "x", count: 1500)
        try Data("old\n".utf8).write(to: old)
        try Data("\(longLine)\n\(longLine)\n\(longLine)\n".utf8).write(to: log)

        let lines = LogFile.recentLines(2, of: log)

        #expect(lines == [longLine[...]])
    }

    @Test func theFollowerGivesWholeNewLinesAndStartsOverAfterAMove() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        try Data("before\n".utf8).write(to: log)
        let follower = LogFile.Follower(log: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        try handle.seekToEnd()
        try handle.write(contentsOf: Data("one\ntw".utf8))
        let first = follower.next()
        try handle.write(contentsOf: Data("o\n".utf8))
        let second = follower.next()
        try Data("new\n".utf8).write(to: log)
        let afterTheMove = follower.next()

        #expect(first == ["one"])
        #expect(second == ["two"])
        #expect(afterTheMove == ["new"])
    }

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hangar-log-\(UUID().uuidString).log")
    }
}
