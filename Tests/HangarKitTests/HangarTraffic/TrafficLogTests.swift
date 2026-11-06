import Foundation
import HangarKit
import HangarSupport
import Testing

@testable import HangarTraffic

struct TrafficLogTests {
    private func write(_ queries: [String], to url: URL) throws {
        let lines = try queries.map { query in
            String(
                decoding: try TrafficLog.encoder.encode(TrafficEvent(time: Date(), kind: .dns, query: query)),
                as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    @Test func recentEventsSpanRotatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)

        try write(["a", "b"], to: TrafficLog.previousURL(of: bundle.trafficLogURL, 2))
        try write(["c", "d"], to: TrafficLog.previousURL(of: bundle.trafficLogURL, 1))
        try write(["e"], to: bundle.trafficLogURL)

        #expect(TrafficLog.recent(in: bundle.trafficLogURL, limit: 4).map(\.query) == ["b", "c", "d", "e"])
        #expect(TrafficLog.recent(in: bundle.trafficLogURL, limit: 10).map(\.query) == ["a", "b", "c", "d", "e"])
        #expect(TrafficLog.recent(in: bundle.trafficLogURL, limit: 1).map(\.query) == ["e"])
    }

    @Test func anExportHoldsTheWholeLogOldestFirstAndOnlyForTheUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = VMBundle(url: directory).trafficLogURL
        let exported = directory.appendingPathComponent("exported.jsonl")
        try write(["a", "b"], to: TrafficLog.previousURL(of: log, 2))
        try write(["c"], to: TrafficLog.previousURL(of: log, 1))
        try write(["d"], to: log)

        try TrafficLog.export(log, to: exported)

        let lines = try String(contentsOf: exported, encoding: .utf8).split(separator: "\n")
        #expect(TrafficLog.decode(lines).map(\.query) == ["a", "b", "c", "d"])
        let attributes = try FileManager.default.attributesOfItem(atPath: exported.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(throws: HangarError.self) { try TrafficLog.export(log, to: log) }
    }

    @Test func aFullLogMovesAsideAndOnlyTheNewestFilesAreKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = VMBundle(url: directory).trafficLogURL
        let writer = TrafficLog.Writer(url: log, maximumSize: 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for query in ["a", "b", "c", "d", "e"] {
            writer.write(TrafficEvent(time: start, kind: .dns, query: query, queryType: "A", verdict: .allowed))
        }
        writer.close()

        #expect(TrafficLog.recent(in: log, limit: 1).map(\.query) == ["e"])
        #expect(TrafficLog.recent(in: log, limit: 10).map(\.query) == ["b", "c", "d", "e"])
        #expect(!FileManager.default.fileExists(atPath: TrafficLog.previousURL(of: log, 4).path))
    }

    @Test func rowsKeepTheirIDsAsOlderEventsFallOutOfTheRecentOnes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let seconds = [0, 1, 2, 3, 3]
        let events = seconds.enumerated().map { index, second in
            TrafficEvent(
                time: start.addingTimeInterval(Double(second)), kind: .request, flow: "a-1", proto: "tcp",
                direction: "out", address: "140.82.121.4", port: 80, host: "github.com", method: "GET",
                path: "/\(index)", verdict: .allowed)
        }

        let all = TrafficReport.connections(from: events)
        let recent = TrafficReport.connections(from: Array(events.dropFirst(2)))

        #expect(Set(all.map(\.id)).count == events.count)
        #expect(Array(all.map(\.id).dropFirst(2)) == recent.map(\.id))
    }

    @Test func lostEntriesAreCountedUntilTheyAreReported() {
        let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/traffic.log")
        let writer = TrafficLog.Writer(url: unwritable)
        let event = TrafficEvent(time: Date(), kind: .dns, query: "github.com", queryType: "A", verdict: .allowed)

        writer.write(event)
        writer.write(event)
        let lost = writer.takeFailedWrites()
        let lostSince = writer.takeFailedWrites()

        #expect(lost == 2)
        #expect(lostSince == 0)
    }

    @Test func writesReadsFollowsAndSummarizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hangar-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        let writer = TrafficLog.Writer(url: bundle.trafficLogURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        writer.write(
            TrafficEvent(
                time: start, kind: .connect, flow: "a-1", proto: "tcp", direction: "out",
                address: "140.82.121.4", port: 443, host: "github.com", verdict: .allowed))
        writer.write(
            TrafficEvent(
                time: start, kind: .dns, query: "evil.example", queryType: "A", verdict: .blocked, reason: "not allowed"
            ))
        let follower = TrafficLog.Follower(url: bundle.trafficLogURL)
        writer.write(
            TrafficEvent(
                time: start.addingTimeInterval(2), kind: .close, flow: "a-1", proto: "tcp", direction: "out",
                address: "140.82.121.4", port: 443, host: "github.com", verdict: .allowed,
                sent: 1200, received: 56_000, duration: 2))
        writer.close()

        #expect(follower.next().map(\.kind) == [.close])
        #expect(follower.next().isEmpty)
        let events = TrafficLog.recent(in: bundle.trafficLogURL, limit: 10)
        #expect(events.map(\.kind) == [.connect, .dns, .close])

        let late = TrafficEvent(
            time: start.addingTimeInterval(-60), kind: .connect, flow: "a-0", proto: "udp", direction: "out",
            address: "224.0.0.22", verdict: .blocked, reason: "isolated")
        #expect(TrafficReport.connections(from: events + [late]).map(\.id) == ["a-0", "a-1"])

        let request = TrafficEvent(
            time: start.addingTimeInterval(1), kind: .request, flow: "a-1", proto: "tcp", direction: "out",
            address: "140.82.121.4", port: 80, host: "github.com", method: "GET", path: "/two", verdict: .allowed)
        let withRequest = TrafficReport.connections(from: events + [request])
        #expect(withRequest.map(\.isRequest) == [false, true])
        #expect(withRequest.last?.path == "/two")

        let connections = TrafficReport.connections(from: events)
        #expect(connections.count == 1)
        #expect(connections[0].endpoint == "140.82.121.4:443")
        #expect(connections[0].received == 56_000)
        #expect(!(connections[0].isOpen))

        let hosts = Dictionary(uniqueKeysWithValues: TrafficReport.hosts(from: events).map { ($0.name, $0) })
        #expect(hosts["github.com"]?.connections == 1)
        #expect(hosts["github.com"]?.received == 56_000)
        #expect(hosts["evil.example"]?.blocked == 1)

        var info = stat()
        #expect(stat(bundle.trafficLogURL.path, &info) == 0)
        #expect(info.st_mode & 0o077 == 0)
    }
}
