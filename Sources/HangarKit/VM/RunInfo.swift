import Darwin
import Foundation

package struct RunInfo: Codable, Hashable, Sendable {
    package enum Host: String, Codable, Sendable {
        case cli
        case app
    }

    package var pid: pid_t
    package var host: Host
    package var startedAt: Date
    package var liveISO: Bool

    package init(pid: pid_t, host: Host, liveISO: Bool = false) {
        self.pid = pid
        self.host = host
        self.startedAt = Date()
        self.liveISO = liveISO
    }
}
