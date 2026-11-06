import Foundation

package enum TrafficReport {
    package static func connections(from events: [TrafficEvent]) -> [TrafficConnection] {
        var order: [String] = []
        var rows: [String: TrafficConnection] = [:]
        var rowIDs = RowIDs()

        for event in events where [.connect, .request, .block, .close].contains(event.kind) {
            let id = rowIDs.id(for: event)
            var row = rows[id] ?? newRow(id, for: event)
            if rows[id] == nil { order.append(id) }
            row.host = event.host ?? row.host
            row.method = event.method ?? row.method
            row.path = event.path ?? row.path
            if event.verdict == .blocked {
                row.verdict = .blocked
                row.reason = event.reason ?? row.reason
            }
            if event.kind == .close {
                row.sent = event.sent
                row.received = event.received
                row.duration = event.duration
            }
            rows[id] = row
        }

        return order.compactMap { rows[$0] }.sorted { $0.time < $1.time }
    }

    /// A flow's events share a row; a request, or an event without a flow, gets one of its own. The ids don't count
    /// rows from the start of the events, so they stay the same as older events fall out of the recent ones and the
    /// app's table keeps its rows and selection.
    private struct RowIDs {
        private var seen: [String: Int] = [:]

        mutating func id(for event: TrafficEvent) -> String {
            if event.kind != .request, let flow = event.flow { return flow }
            let key = "\(event.flow ?? event.kind.rawValue)-\(event.time.timeIntervalSince1970)"
            let number = seen[key, default: 0] + 1
            seen[key] = number
            return "\(key)-\(number)"
        }
    }

    private static func newRow(_ id: String, for event: TrafficEvent) -> TrafficConnection {
        TrafficConnection(
            id: id, time: event.time, proto: event.kind == .request ? "http" : event.proto ?? "",
            direction: event.direction ?? "out", address: event.address ?? "–", port: event.port, host: event.host,
            method: event.method, path: event.path, verdict: event.verdict ?? .allowed, reason: event.reason)
    }

    package static func hosts(from events: [TrafficEvent]) -> [TrafficHost] {
        var hosts: [String: TrafficHost] = [:]

        for event in events {
            let name: String
            switch event.kind {
            case .dns: name = event.query ?? "–"
            case .connect, .block, .close: name = event.host ?? event.address ?? "–"
            case .start, .policy, .notice, .request: continue
            }

            var host = hosts[name] ?? TrafficHost(name: name)
            switch event.kind {
            case .dns: host.lookups += 1
            case .connect: host.connections += 1
            case .close:
                host.sent += event.sent ?? 0
                host.received += event.received ?? 0
            case .block, .start, .policy, .notice, .request: break
            }
            if event.verdict == .blocked, event.kind != .close { host.blocked += 1 }
            host.lastSeen = max(host.lastSeen, event.time)
            hosts[name] = host
        }

        return hosts.values.sorted { first, second in
            let (a, b) = (first.connections + first.lookups, second.connections + second.lookups)
            return a != b ? a > b : first.name < second.name
        }
    }
}
