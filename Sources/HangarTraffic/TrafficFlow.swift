import Foundation
import HangarPackets

struct FlowKey: Hashable {
    let protocolNumber: UInt8
    let guestPort: UInt16
    let remote: UInt32
    let remotePort: UInt16
}

final class TrafficFlow {
    enum Direction: String {
        case outbound = "out"
        case inbound = "in"
    }

    enum Application {
        case tls
        case http
        case other
    }

    let id: String
    let key: FlowKey
    let direction: Direction
    let startedAt: Date
    var lastSeen: Date
    /// Lowercased, as the DNS parser gives them.
    var names: [String]
    var trustedNames: [String]
    var application: Application?
    var serverName: String?
    var method: String?
    var path: String?
    var verdict = TrafficEvent.Verdict.allowed
    var reason: String?
    var isBlockedAfterClosing = false
    var wasAnnounced = false
    var isQuiet = false
    var sent: UInt64 = 0
    var received: UInt64 = 0
    var isInspecting = false
    var clientStart: UInt32?
    // Past the data the SYN carried (TCP Fast Open); the server acknowledges this or clientStart.
    var openingEnd: UInt32 = 0
    var bufferStart: UInt32 = 0
    var clientBytes: [UInt8] = []
    var http: HTTPStream?
    var dns: DNSStream?
    var hasGuestFinished = false
    var hasRemoteFinished = false
    var wasReset = false
    /// Sent to the secrets proxy instead of its server (`TrafficInspector+Secrets`).
    var isDiverted = false
    var isEstablished = false
    var hasSentAheadOfTheServer = false

    init(id: String, key: FlowKey, direction: Direction, names: [String], trustedNames: [String], now: Date) {
        self.id = id
        self.key = key
        self.direction = direction
        self.names = names
        self.trustedNames = trustedNames
        startedAt = now
        lastSeen = now
    }

    var host: String? { serverName ?? names.first }
    var isFollowedFromItsSYN: Bool { clientStart != nil }

    var protocolName: String { Self.protocolName(key.protocolNumber) }

    static func protocolName(_ protocolNumber: UInt8) -> String {
        switch protocolNumber {
        case Packet.protocolTCP: "tcp"
        case Packet.protocolUDP: "udp"
        case Packet.protocolICMP: "icmp"
        default: "ip\(protocolNumber)"
        }
    }

    var isClosed: Bool { wasReset || (hasGuestFinished && hasRemoteFinished) }

    /// How long a flow stays after its last frame.
    static let blockedIdle: TimeInterval = 10
    static let closedIdle: TimeInterval = 10
    static let establishedIdle: TimeInterval = 7200
    static let handshakeIdle: TimeInterval = 60
    static let icmpIdle: TimeInterval = 30
    static let datagramIdle: TimeInterval = 120

    func idleLimit() -> TimeInterval {
        if verdict == .blocked { return Self.blockedIdle }
        switch key.protocolNumber {
        case Packet.protocolTCP:
            if isClosed { return Self.closedIdle }
            return isEstablished ? Self.establishedIdle : Self.handshakeIdle
        case Packet.protocolICMP: return Self.icmpIdle
        default: return Self.datagramIdle
        }
    }

    func event(_ kind: TrafficEvent.Kind, now: Date) -> TrafficEvent {
        let shown = isBlockedAfterClosing ? TrafficEvent.Verdict.allowed : verdict
        var event = TrafficEvent(
            time: kind == .connect ? startedAt : now, kind: kind, flow: id, proto: protocolName,
            direction: direction.rawValue, address: IPv4Address(key.remote).description,
            host: host, method: method, path: path, verdict: shown,
            reason: isBlockedAfterClosing ? nil : reason)
        let port = direction == .inbound ? key.guestPort : key.remotePort

        if key.protocolNumber != Packet.protocolICMP, port != 0 {
            event.port = Int(port)
        }

        if kind == .close {
            event.sent = sent
            event.received = received
            // The log keeps whole milliseconds.
            event.duration = (now.timeIntervalSince(startedAt) * 1000).rounded() / 1000
        }

        return event
    }
}
