import Foundation
import HangarSupport
import Testing

@testable import HangarKit

struct ExecFrameTests {
    /// The same bytes are in hangar_exec_frames' tests: the host writes this start, and reads this exit.
    private static let startGolden = "010000001d0300500018000561646d696e000200000005756e616d65000000022d61"
    private static let exitGolden = "1400000004fffffffd"

    private static func bytes(_ hex: String) -> Data {
        var bytes = Data()
        var rest = Substring(hex)
        while !rest.isEmpty {
            bytes.append(UInt8(rest.prefix(2), radix: 16) ?? 0)
            rest = rest.dropFirst(2)
        }
        return bytes
    }

    private static func frames(in chunks: [Data]) throws -> [ExecFrame] {
        var reader = ExecFrameReader()
        var frames: [ExecFrame] = []
        for chunk in chunks {
            reader.feed(chunk)
            while let frame = try reader.nextFrame() {
                frames.append(frame)
            }
        }
        return frames
    }

    @Test func theStartFrameIsWrittenTheWayTheAgentReadsIt() throws {
        let request = ExecRequest(command: ["uname", "-a"], tty: true, interactive: true, columns: 80, rows: 24)

        let frame = ExecFrame(.start, payload: try request.startPayload(fallbackUser: "admin"))

        #expect(frame.encoded == Self.bytes(Self.startGolden))
    }

    @Test func theAgentsExitFrameReadsAsItsCode() throws {
        let frames = try Self.frames(in: [Self.bytes(Self.exitGolden)])

        #expect(frames.count == 1)
        #expect(frames.first?.exitCode == -3)
    }

    @Test func aFrameSplitAcrossReadsComesOutWhole() throws {
        let encoded = ExecFrame(.output, payload: Data("hello".utf8)).encoded

        let frames = try Self.frames(in: [encoded.prefix(3), encoded.dropFirst(3)])

        #expect(frames == [ExecFrame(.output, payload: Data("hello".utf8))])
    }

    @Test func anOverLongOrUnknownFrameEndsTheConnection() {
        let tooLong = Data([18]) + Data(bigEndian: UInt32(ExecFrame.maximumPayload + 1))
        let unknownKind = Data([99, 0, 0, 0, 0])

        #expect(throws: HangarError.self) { try Self.frames(in: [tooLong]) }
        #expect(throws: HangarError.self) { try Self.frames(in: [unknownKind]) }
    }

    @Test func aFailedFramesReasonReachesTheTerminalWithoutControlCharacters() {
        let frame = ExecFrame.failed("no \u{1b}]52;c;aGk=\u{7}such user")

        #expect(frame.message == "no ?]52;c;aGk=?such user")
    }

    @Test func aCommandThatDoesntFitInAFrameIsRefusedBeforeItIsSent() {
        let request = ExecRequest(
            command: ["echo", String(repeating: "a", count: ExecFrame.maximumPayload)], tty: false,
            interactive: false, columns: 80, rows: 24)

        let refusal = failureMessage { _ = try request.startPayload(fallbackUser: nil) }

        #expect(refusal == "The command is too long for hangar exec; put it in a script and run that.")
    }
}
