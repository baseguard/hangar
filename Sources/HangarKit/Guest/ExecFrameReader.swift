import Foundation
import HangarSupport

/// Collects the bytes of a connection and hands out whole frames. An unknown kind or an over-long payload means the other
/// side isn't speaking exec frames, so the connection can't go on.
package struct ExecFrameReader: Sendable {
    private var buffer: [UInt8] = []

    package init() {}

    package mutating func feed(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// Nil until a whole frame is in.
    package mutating func nextFrame() throws -> ExecFrame? {
        guard buffer.count >= ExecFrame.headerSize else { return nil }
        guard let kind = ExecFrame.Kind(rawValue: buffer[0]) else {
            throw HangarError("The VM sent hangar exec a frame it doesn't know.")
        }
        let length = Int(buffer[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= ExecFrame.maximumPayload else {
            throw HangarError("The VM sent hangar exec a frame over 64 KiB.")
        }

        let end = ExecFrame.headerSize + length
        guard buffer.count >= end else { return nil }
        let payload = Data(buffer[ExecFrame.headerSize..<end])
        buffer.removeFirst(end)
        return ExecFrame(kind, payload: payload)
    }
}
