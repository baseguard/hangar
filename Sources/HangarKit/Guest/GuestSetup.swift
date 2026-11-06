import Foundation

package enum GuestSetup {
    package static let agentVersion = 34
    /// The first agent that takes `hangar exec` commands.
    package static let firstExecAgentVersion = 17
    /// The first agent with the `cp-in` and `cp-out` commands behind `hangar cp`.
    package static let firstCopyAgentVersion = 19
    /// The first agent whose `take` puts dropped files in the HangarDrop folder in the user's home.
    package static let firstDropAgentVersion = 22
    /// The first agent with the `ls` command that lists a guest folder for browsing its files.
    package static let firstBrowseAgentVersion = 28
}
