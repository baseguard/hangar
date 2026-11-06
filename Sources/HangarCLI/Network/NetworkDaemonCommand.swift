import ArgumentParser
import Foundation
import HangarKit

struct NetworkDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_netd", shouldDisplay: false)

    func run() throws {
        NetworkDaemon.run()
    }
}
