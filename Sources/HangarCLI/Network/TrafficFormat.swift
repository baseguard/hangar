import Foundation
import HangarKit
import HangarSupport
import HangarTraffic

enum TrafficFormat {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func line(_ connection: TrafficConnection) -> String {
        var detail: [String] = []
        if let method = connection.method { detail.append("\(method) \(connection.path ?? "")") }

        if connection.isRequest {
            return row(
                connection.time, nil, "http", connection.destination, connection.endpoint,
                detail.joined(separator: "  "))
        }

        if connection.verdict == .blocked {
            detail.append(connection.reason ?? "blocked")
        } else if let sent = connection.sent, let received = connection.received {
            detail.append("↑\(ByteSize.format(sent)) ↓\(ByteSize.format(received))")
        } else {
            detail.append("open")
        }

        let proto = connection.direction == "in" ? "\(connection.proto) in" : connection.proto

        return row(
            connection.time, connection.verdict, proto, connection.destination, connection.endpoint,
            detail.joined(separator: "  "))
    }

    static func event(_ event: TrafficEvent) -> String {
        guard let connection = TrafficReport.connections(from: [event]).first else { return "" }
        guard event.kind == .close else { return line(connection) }
        return row(
            event.time, nil, "end", connection.destination, connection.endpoint,
            "↑\(ByteSize.format(event.sent ?? 0)) ↓\(ByteSize.format(event.received ?? 0))  \(String(format: "%.1fs", event.duration ?? 0))"
        )
    }

    static func dns(_ event: TrafficEvent) -> String {
        let question = "\(event.query ?? "?") \(event.queryType ?? "")"
        let detail =
            event.verdict == .blocked
            ? (event.reason ?? "blocked")
            : [event.answers.map { $0.isEmpty ? "no addresses" : "→ " + $0.joined(separator: ", ") }, event.reason]
                .compactMap { $0 }.joined(separator: "  ")
        return row(event.time, event.verdict, "dns", question, "", detail)
    }

    static func notice(_ event: TrafficEvent, _ text: String) -> String {
        let reason = event.kind == .notice ? nil : event.reason
        return "\(time(event.time))  ----   " + text + (reason.map { ", \($0)" } ?? "")
    }

    private static func row(
        _ date: Date, _ verdict: TrafficEvent.Verdict?, _ kind: String, _ destination: String,
        _ endpoint: String, _ detail: String
    ) -> String {
        let mark =
            switch verdict {
            case .blocked: "BLOCK"
            case .allowed: "allow"
            case nil: "     "
            }
        return [time(date), mark, pad(kind, 6), pad(destination, 34), pad(endpoint, 22), detail].joined(separator: "  ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let fitted = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return fitted.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
