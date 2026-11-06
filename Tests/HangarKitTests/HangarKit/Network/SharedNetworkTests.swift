import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct SharedNetworkTests {
    @Test func aDaemonThatHasNotSetUpItsNetworkIsStillFound() throws {
        try HangarPaths.createDirectory(SharedNetwork.directory)
        let lock = FileLock(url: SharedNetwork.daemonLockURL)
        #expect(try lock.tryLock(.exclusive))
        try lock.write(Data("\(getpid())\n".utf8))

        let state = SharedNetwork.state
        let holder = SharedNetwork.daemonHoldingLock

        #expect(state == nil)
        #expect(holder == getpid())
        lock.unlock()
        #expect(SharedNetwork.daemonHoldingLock == nil)
    }
}
