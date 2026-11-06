import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the log of a VM started in the background.",
        discussion: """
            Examples:
              hangar logs deb
                  The last 50 lines.
              hangar logs deb --follow
                  Keep printing new lines as the VM writes them.
              hangar network logs
                  The log of Hangar's network.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @OptionGroup var options: LogOptions

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        options.show(
            bundle.logURL, emptyHint: "'\(name)' has no log yet. Hangar keeps one for VMs started in the background.")
    }
}
