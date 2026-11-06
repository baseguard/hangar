import Foundation

package struct GuestMemory: Hashable, Codable, Sendable {
    package let used: UInt64
    package let total: UInt64

    package init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }

    static let ceiling: UInt64 = 1 << 40
}

/// The guest agent's `hangar_report` crate writes it; a change to the fields goes in both.
package struct GuestReport: Hashable, Codable, Sendable {
    package let memory: GuestMemory
    package let agentVersion: Int
    /// Only Linux agents say; false when the guest's kernel drives no screen, so its window shows
    /// nothing after the boot screen.
    package let hasScreen: Bool?

    package init(memory: GuestMemory, agentVersion: Int, hasScreen: Bool? = nil) {
        self.memory = memory
        self.agentVersion = agentVersion
        self.hasScreen = hasScreen
    }

    static let versionCeiling: UInt64 = 1_000_000

    /// The agent's own names, so its line and the control socket's answer decode alike.
    private enum CodingKeys: String, CodingKey {
        case memory
        case agentVersion = "version"
        case hasScreen = "screen"
    }

    /// Only whole numbers in range, and a true or false for the screen; JSONDecoder refuses `true` as 1 and 1.5 as 1.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let memory = try container.decode(GuestMemory.self, forKey: .memory)
        let version = try container.decode(UInt64.self, forKey: .agentVersion)
        let hasScreen = try container.decodeIfPresent(Bool.self, forKey: .hasScreen)
        guard Self.isPlausible(memory: memory, version: version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .memory, in: container, debugDescription: "The guest report is out of range.")
        }
        self.init(memory: memory, agentVersion: Int(version), hasScreen: hasScreen)
    }

    /// The one place that decides which reports to believe, for the agent port and for saved reports alike.
    static func isPlausible(memory: GuestMemory, version: UInt64) -> Bool {
        memory.used <= memory.total && memory.total > 0 && memory.total <= GuestMemory.ceiling
            && version <= versionCeiling
    }
}
