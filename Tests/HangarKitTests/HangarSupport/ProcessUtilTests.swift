import Darwin
import Foundation
import Testing

@testable import HangarSupport

struct ProcessUtilTests {
    @Test func aDetachedProcessHasItsOwnSessionNoInputAndAppendsToItsLog() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        try Data("before\n".utf8).write(to: log)
        let script = "echo out; echo err >&2; read line || echo no-input; exec sleep 30"

        let pid = try ProcessUtil.spawnDetached(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], logURL: log)
        defer { stopIfRunning(pid) }

        let hasWritten = ProcessUtil.wait(timeout: 5) {
            (try? String(contentsOf: log, encoding: .utf8))?.hasSuffix("no-input\n") == true
        }
        #expect(hasWritten)
        #expect(try String(contentsOf: log, encoding: .utf8) == "before\nout\nerr\nno-input\n")
        #expect(getsid(pid) == pid)
    }

    /// Swift Testing runs this on a pool thread, which blocks SIGTERM; the child must not inherit that.
    @Test func aDetachedProcessStopsOnSIGTERM() throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try ProcessUtil.spawnDetached(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], logURL: log)
        defer { stopIfRunning(pid) }

        kill(pid, SIGTERM)

        #expect(ProcessUtil.wait(timeout: 5) { ProcessUtil.hasExited(pid) })
    }

    @Test func aLogPastItsLimitMovesAsideWhenTheNextProcessStarts() throws {
        let log = temporaryLog()
        let old = LogFile.movedAside(log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: old)
        }
        try Data(count: Int(LogFile.sizeLimit) + 1).write(to: log)

        let pid = try ProcessUtil.spawnDetached(URL(fileURLWithPath: "/bin/echo"), arguments: ["fresh"], logURL: log)
        defer { stopIfRunning(pid) }

        #expect(ProcessUtil.wait(timeout: 5) { ProcessUtil.hasExited(pid) })
        #expect(try String(contentsOf: log, encoding: .utf8) == "fresh\n")
        let oldSize = try FileManager.default.attributesOfItem(atPath: old.path)[.size] as? Int
        #expect(oldSize == Int(LogFile.sizeLimit) + 1)
    }

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hangar-spawn-\(UUID().uuidString).log")
    }

    /// Only a child still waiting to be reaped is killed, never a process that has taken its number since.
    private func stopIfRunning(_ pid: pid_t) {
        if !ProcessUtil.hasExited(pid) { kill(pid, SIGKILL) }
    }
}
