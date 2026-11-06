import ArgumentParser
import Foundation
import HangarKit

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Let a paused VM carry on where it stopped.")

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    func run() throws {
        _ = try ControlClient.send(.resume, to: try runningBundle(named: name))
        print("Resumed '\(name)'.")
    }
}
