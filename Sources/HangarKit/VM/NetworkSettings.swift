import Foundation

package struct NetworkSettings: Codable, Hashable, Sendable {
    package var mode: NetworkMode
    package var macAddress: String
    package var ipAddress: String?

    package init(mode: NetworkMode, macAddress: String, ipAddress: String? = nil) {
        self.mode = mode
        self.macAddress = macAddress
        self.ipAddress = ipAddress
    }
}
