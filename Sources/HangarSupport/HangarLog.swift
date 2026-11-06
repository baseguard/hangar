import Foundation
import OSLog

package enum HangarLog {
    package static func logger(_ category: String) -> Logger {
        Logger(subsystem: "io.baseguard.hangar", category: category)
    }

    package static func warning(_ message: String) {
        logger("general").warning("\(message, privacy: .public)")
        try? FileHandle.standardError.write(contentsOf: Data("warning: \(message)\n".utf8))
    }
}
