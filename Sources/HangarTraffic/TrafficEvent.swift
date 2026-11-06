import Darwin
import Foundation

package struct TrafficEvent: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case start
        case policy
        case notice
        case dns
        case connect
        case request
        case block
        case close
    }

    package enum Verdict: String, Codable, Sendable {
        case allowed
        case blocked
    }

    package var time: Date
    package var kind: Kind
    package var flow: String?
    package var proto: String?
    package var direction: String?
    package var address: String?
    package var port: Int?
    package var host: String?
    package var method: String?
    package var path: String?
    package var query: String?
    package var queryType: String?
    package var answers: [String]?
    package var verdict: Verdict?
    package var reason: String?
    package var sent: UInt64?
    package var received: UInt64?
    package var duration: Double?
    package var mode: String?
}

extension TrafficEvent {
    /// A request the secrets proxy sent on with secrets in it. The path is the guest's, with placeholders, never values.
    package static func secretsUsed(_ names: [String], host: String, method: String, path: String, now: Date)
        -> TrafficEvent
    {
        TrafficEvent(
            time: now, kind: .request, host: host, method: method, path: path, verdict: .allowed,
            reason: "secret \(names.joined(separator: ", ")) put in")
    }

    /// An answer the guest got with these secrets' values masked, because the host sent them back.
    package static func secretsMasked(_ names: [String], host: String, now: Date) -> TrafficEvent {
        TrafficEvent(
            time: now, kind: .request, host: host, method: "", path: "", verdict: .allowed,
            reason: "secret \(names.joined(separator: ", ")) masked in the answer")
    }

    /// A request the secrets proxy answered itself instead of sending it on.
    package static func secretsRefused(host: String, method: String, path: String, reason: String, now: Date)
        -> TrafficEvent
    {
        TrafficEvent(time: now, kind: .block, host: host, method: method, path: path, verdict: .blocked, reason: reason)
    }
}
