import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct ExecCommandTests {
    /// The command's own options, like `-la`, belong to it, with or without `--`.
    @Test(arguments: [["exec", "box", "--", "uname", "-a"], ["exec", "box", "ls", "-la"]])
    func aStoppedVMSaysHowToStartIt(arguments: [String]) throws {
        _ = try TestVM.make(.linux, named: "box")

        let result = try HangarCommand.run(arguments)

        #expect(result.status == 1)
        #expect(result.error == "Error: 'box' isn't running. Start it: hangar run box\n")
    }
}
