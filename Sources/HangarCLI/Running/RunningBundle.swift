import Foundation
import HangarKit
import HangarSupport

func runningBundle(named name: String) throws -> VMBundle {
    let bundle = try VMLibrary.bundle(named: name)
    guard bundle.isRunning else { throw HangarError("'\(name)' is not running.") }
    return bundle
}
