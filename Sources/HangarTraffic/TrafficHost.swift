import Foundation

package struct TrafficHost: Identifiable, Hashable, Sendable {
    package let name: String
    package var connections = 0
    package var lookups = 0
    package var blocked = 0
    package var sent: UInt64 = 0
    package var received: UInt64 = 0
    package var lastSeen = Date.distantPast

    package var id: String { name }
}
