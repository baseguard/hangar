import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct IP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Print a running VM's IP address.",
        discussion: """
            Examples:
              ssh dev@$(hangar ip deb)
                  Sign in to deb over SSH.
              hangar run deb --background && ssh dev@$(hangar ip deb --wait 60)
                  Start deb and sign in as soon as it has an address.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @Option(
        name: .customLong("wait"),
        help: ArgumentHelp("Default: 0. Wait up to this many seconds for the address.", valueName: "seconds"))
    var waitOption: Int?

    private var wait: Int { waitOption ?? 0 }

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        let config = try bundle.loadConfig()
        guard let run = bundle.runInfo else { throw HangarError("'\(bundle.name)' is not running.") }

        runMain { [wait] in
            let timeout = TimeInterval(wait)
            guard let address = await IPResolver.waitForAddress(for: config, startedAt: run.startedAt, timeout: timeout)
            else { throw HangarError("No IP address for '\(bundle.name)' yet.") }
            print(address)
        }
    }
}
