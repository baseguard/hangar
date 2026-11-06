import ArgumentParser
import Foundation
import HangarKit

struct FirstStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "first-start",
        abstract: "Set up a new image VM on its first start; runs as root inside the guest.",
        shouldDisplay: false
    )

    func run() throws {
        try ImageFirstStart.run { line in
            print("[\(Date().formatted(.iso8601))] \(line)")
            fflush(stdout)
        }
    }
}
