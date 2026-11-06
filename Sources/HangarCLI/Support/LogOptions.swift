import ArgumentParser
import Foundation
import HangarSupport

/// How much of a log `hangar logs`, `hangar network logs` and `hangar traffic` show.
struct LogOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Keep printing new lines until you press Ctrl+C.")
    var follow = false

    @Option(
        name: [.customShort("n"), .customLong("count")],
        help: ArgumentHelp("Default: \(LogOptions.defaultCount). How many recent lines to show.", valueName: "lines"))
    var countOption: Int?

    var count: Int { countOption ?? Self.defaultCount }
    static let defaultCount = 50
    /// Far more than anyone reads in a terminal.
    private static let largestCount = 100_000
    /// How often `--follow` looks for new lines.
    static let followInterval: TimeInterval = 0.5

    func validate() throws {
        guard (1...Self.largestCount).contains(count) else {
            throw ValidationError("--count must be between 1 and \(Self.largestCount).")
        }
    }

    /// The end of `log` and, with --follow, each line written to it from then on.
    func show(_ log: URL, emptyHint: String) {
        let recent = LogFile.recentLines(count, of: log)
        if recent.isEmpty, !follow {
            print(emptyHint)
            return
        }

        for line in recent {
            print(line)
        }
        guard follow else { return }

        let follower = LogFile.Follower(log: log)
        while true {
            for line in follower.next() {
                print(line)
            }
            fflush(stdout)
            Thread.sleep(forTimeInterval: Self.followInterval)
        }
    }
}
