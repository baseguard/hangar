import Foundation
import HangarPackets
import Synchronization

/// The guest's HTTPS connections the inspector sent to the secrets proxy instead of their server, by the guest's
/// address and port. The proxy takes each one once, when it accepts the connection, and serves nothing else: another
/// VM or a program on the Mac that reaches the proxy finds no entry.
package final class DivertedConnections: Sendable {
    package struct Destination: Equatable, Sendable {
        package let server: TCPRedirect.Endpoint
        /// The names the guest's DNS answers gave the server's address.
        package let names: [String]
    }

    private struct Entry {
        let destination: Destination
        let divertedAt: Date
        var isTaken = false

        func hasExpired(at now: Date) -> Bool {
            !isTaken && now.timeIntervalSince(divertedAt) > DivertedConnections.acceptLimit
        }
    }

    /// More would let a guest use up the host process's descriptors.
    static let limit = 256
    /// A connection the proxy didn't accept by then never reached it.
    static let acceptLimit: TimeInterval = 30

    private let entries = Mutex<[TCPRedirect.Endpoint: Entry]>([:])

    package init() {}

    /// False when too many are open; the connection then goes to its server as it is.
    func add(_ guest: TCPRedirect.Endpoint, to destination: Destination, now: Date) -> Bool {
        entries.withLock { entries in
            entries = entries.filter { !$0.value.hasExpired(at: now) }
            guard entries.count < Self.limit else { return false }
            entries[guest] = Entry(destination: destination, divertedAt: now)
            return true
        }
    }

    func remove(_ guest: TCPRedirect.Endpoint) {
        entries.withLock { _ = $0.removeValue(forKey: guest) }
    }

    /// Where the guest's connection was going; `nil` for a connection that wasn't diverted, or was accepted before.
    package func take(_ guest: TCPRedirect.Endpoint, now: Date = Date()) -> Destination? {
        entries.withLock { entries in
            guard var entry = entries[guest], !entry.isTaken, !entry.hasExpired(at: now) else { return nil }
            entry.isTaken = true
            entries[guest] = entry
            return entry.destination
        }
    }
}
