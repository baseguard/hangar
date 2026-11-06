import Foundation

package struct TrafficConnection: Identifiable, Hashable, Sendable {
    package let id: String
    package var time: Date
    package var proto: String
    package var direction: String
    package var address: String
    package var port: Int?
    package var host: String?
    package var method: String?
    package var path: String?
    package var verdict: TrafficEvent.Verdict
    package var reason: String?
    package var sent: UInt64?
    package var received: UInt64?
    package var duration: Double?

    package var destination: String { host ?? address }
    package var endpoint: String { port.map { "\(address):\($0)" } ?? address }
    package var isRequest: Bool { proto == "http" }
    package var isOpen: Bool { duration == nil && verdict == .allowed && !isRequest }
}
