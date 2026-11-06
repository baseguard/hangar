import Darwin
import Foundation
import Testing

@testable import HangarKit

/// The bridge between a caller and a fake guest, each on a socket pair.
@Suite(.timeLimit(.minutes(1)))
struct ExecBridgeTests {
    /// The caller's and the guest's ends, after the bridge took the other two.
    private static func bridge(start: Data = ExecFrame(.start).encoded) throws -> (caller: Int32, guest: Int32) {
        let callerPair = try makeSocketPair()
        let guestPair = try makeSocketPair()
        ExecBridge.relay(caller: callerPair.0, guest: guestPair.0, start: start)
        return (callerPair.1, guestPair.1)
    }

    @Test func theGuestGetsTheStartThenTheCallersFrames() throws {
        let ends = try Self.bridge()
        defer {
            close(ends.caller)
            close(ends.guest)
        }
        let caller = ExecConnection(readFD: ends.caller, writeFD: ends.caller)
        let guest = ExecConnection(readFD: ends.guest, writeFD: ends.guest)

        try caller.send(ExecFrame(.input, payload: Data("hello".utf8)))
        try guest.send(.exit(code: 3))

        #expect(try guest.receive() == ExecFrame(.start))
        #expect(try guest.receive() == ExecFrame(.input, payload: Data("hello".utf8)))
        #expect(try caller.receive()?.exitCode == 3)
    }

    @Test func aCallerThatLeavesClosesTheGuestsConnection() throws {
        let ends = try Self.bridge()
        defer { close(ends.guest) }
        let guest = ExecConnection(readFD: ends.guest, writeFD: ends.guest)
        #expect(try guest.receive() == ExecFrame(.start))

        close(ends.caller)

        #expect(try guest.receive() == nil)
    }

    @Test func aGuestThatLeavesClosesTheCallersConnection() throws {
        let ends = try Self.bridge()
        defer { close(ends.caller) }
        let caller = ExecConnection(readFD: ends.caller, writeFD: ends.caller)

        close(ends.guest)

        #expect(try caller.receive() == nil)
    }
}
