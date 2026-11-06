import Darwin
import Foundation
import HangarSupport
import Testing

@testable import HangarKit

/// A copy out of a guest that never answers: the other end of a socket pair plays the guest and sends nothing.
@Suite(.timeLimit(.minutes(1)))
struct GuestCopyTests {
    private static let vm = VMBundle(url: URL(filePath: "/tmp/deb", directoryHint: .isDirectory))
    private static let folder = FileManager.default.temporaryDirectory

    @Test func aGuestThatSendsNothingFailsTheCopy() throws {
        let (mac, guest) = try makeSocketPair()
        defer { close(guest) }

        let error = #expect(throws: HangarError.self) {
            try GuestCopy.copyOut(
                over: mac, into: Self.folder, as: "copy-\(UUID().uuidString)", in: Self.vm, errors: { _ in },
                stop: CopyStop(), receiveTimeout: 1)
        }

        #expect(error?.message == "'deb' stopped answering during the copy.")
    }

    @Test func aStopEndsACopyWaitingOnTheGuestAtOnce() async throws {
        let (mac, guest) = try makeSocketPair()
        defer { close(guest) }
        let stop = CopyStop()
        let copy = Task.detached {
            try GuestCopy.copyOut(
                over: mac, into: Self.folder, as: "copy-\(UUID().uuidString)", in: Self.vm, errors: { _ in },
                stop: stop)
        }
        try await Task.sleep(for: .milliseconds(200))

        let stoppedAt = ContinuousClock.now
        stop.stop()
        let result = await copy.result

        #expect(ContinuousClock.now - stoppedAt < .seconds(1))
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func closingACopysConnectionEndsTheThreadWaitingForTheCommandsEnd() throws {
        let (mac, guest) = try makeSocketPair()
        defer { close(guest) }
        let exit = GuestCopy.Exit(reading: mac, errors: { _ in })

        CopyStop().close(mac)

        let error = #expect(throws: HangarError.self) { try exit.wait(in: Self.vm, upTo: .seconds(5)) }
        #expect(error?.message == "The VM stopped answering before the copy finished.")
        var byte: UInt8 = 0
        #expect(read(guest, &byte, 1) == 0)
    }
}
