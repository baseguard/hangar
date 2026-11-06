import Foundation
import HangarSupport

/// A frame on a `hangar exec` connection, laid out like `hangar_exec_frames` in the guest agent; a change to the layout
/// goes in both. `hangar exec` and the guest agent speak them, one connection per command, and the VM's process only
/// passes the bytes along.
///
/// A frame is a kind byte, the payload length as a big-endian `UInt32`, then the payload.
package struct ExecFrame: Equatable, Sendable {
    package enum Kind: UInt8, Sendable {
        // Host to guest.
        case start = 1
        case input = 2
        case resize = 3
        // Guest to host.
        case output = 18
        case errorOutput = 19
        case exit = 20
        case failed = 21
    }

    package static let maximumPayload = 64 * 1024
    static let headerSize = 5

    package var kind: Kind
    package var payload: Data

    package init(_ kind: Kind, payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }

    package static func resize(columns: UInt16, rows: UInt16) -> ExecFrame {
        ExecFrame(.resize, payload: Data(bigEndian: columns) + Data(bigEndian: rows))
    }

    package static func exit(code: Int32) -> ExecFrame {
        ExecFrame(.exit, payload: Data(bigEndian: code))
    }

    package static func failed(_ message: String) -> ExecFrame {
        ExecFrame(.failed, payload: Data(message.utf8.prefix(maximumPayload)))
    }

    package var encoded: Data {
        var bytes = Data([kind.rawValue])
        bytes.append(Data(bigEndian: UInt32(payload.count)))
        bytes.append(payload)
        return bytes
    }

    /// The command's exit code, for an exit frame.
    package var exitCode: Int32? {
        guard kind == .exit, payload.count == 4 else { return nil }
        return payload.reduce(0) { $0 << 8 | Int32($1) }
    }

    /// Why the command couldn't run, for a failed frame. A guest can replace its agent, so the reason loses its
    /// control characters before it reaches the user's terminal or an alert.
    package var message: String {
        String(decoding: payload.withoutControlCharacters, as: UTF8.self)
    }
}

extension Data {
    init(bigEndian value: some FixedWidthInteger) {
        self.init(Swift.withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }
}
