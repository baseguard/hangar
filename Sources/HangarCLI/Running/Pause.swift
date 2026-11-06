import ArgumentParser
import Foundation
import HangarKit

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause a running VM; it keeps its memory but stops using the processor.")

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    func run() throws {
        _ = try ControlClient.send(.pause, to: try runningBundle(named: name))
        print("Paused '\(name)'.")
    }
}
