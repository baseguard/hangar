import Foundation
import HangarKit
import HangarTraffic

nonisolated struct TrafficActivity: Equatable, Sendable {
    struct Bucket: Identifiable, Sendable {
        let start: Date
        let kind: String
        let count: Int
        var id: String { "\(start.timeIntervalSince1970)-\(kind)" }
    }

    static let timelineMinutes = 30

    var connections: [TrafficConnection] = []
    var hosts: [TrafficHost] = []
    var lookups: [TrafficLookup] = []
    var latest: Date?
    var count = 0
    var blocked = 0
    var sent: UInt64 = 0
    var received: UInt64 = 0
    var timeline: [Bucket] = []

    init() {}

    /// Enough for the tables and the timeline; the full log is on disk for `hangar traffic`.
    static let eventLimit = 5000

    @concurrent
    static func load(from bundle: VMBundle) async -> TrafficActivity {
        TrafficActivity(events: TrafficLog.recent(in: bundle.trafficLogURL, limit: eventLimit))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.latest == rhs.latest
    }

    init(events: [TrafficEvent]) {
        connections = TrafficReport.connections(from: events).reversed()
        hosts = TrafficReport.hosts(from: events)
        var seen: [String: Int] = [:]
        lookups = events.filter { $0.kind == .dns }.map { event in
            let key = "\(event.time.timeIntervalSince1970)-\(event.query ?? "")-\(event.queryType ?? "")"
            seen[key, default: 0] += 1
            return TrafficLookup(id: "\(key)-\(seen[key] ?? 0)", event: event)
        }.reversed()
        latest = events.last?.time
        count = events.count
        blocked =
            connections.count { $0.verdict == .blocked } + lookups.count { $0.event.verdict == .blocked }
        sent = hosts.reduce(0) { $0 + $1.sent }
        received = hosts.reduce(0) { $0 + $1.received }
        timeline = Self.buckets(connections, end: latest ?? Date())
    }

    private static func buckets(_ connections: [TrafficConnection], end: Date) -> [Bucket] {
        let start = end.addingTimeInterval(-Double(timelineMinutes * 60))
        var counts: [Date: (allowed: Int, blocked: Int)] = [:]
        for connection in connections where connection.time > start && connection.time <= end {
            let minute = Date(timeIntervalSince1970: (connection.time.timeIntervalSince1970 / 60).rounded(.down) * 60)
            if connection.verdict == .blocked {
                counts[minute, default: (0, 0)].blocked += 1
            } else {
                counts[minute, default: (0, 0)].allowed += 1
            }
        }
        return counts.keys.sorted().flatMap { minute in
            [
                Bucket(start: minute, kind: "Allowed", count: counts[minute]?.allowed ?? 0),
                Bucket(start: minute, kind: "Blocked", count: counts[minute]?.blocked ?? 0),
            ].filter { $0.count > 0 }
        }
    }
}
