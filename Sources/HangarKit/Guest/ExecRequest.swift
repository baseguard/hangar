import Foundation
import HangarSupport

/// What `hangar exec` asks a running VM to do; it travels to the VM's process as JSON and on to the guest as the
/// payload of a start frame.
package struct ExecRequest: Codable, Equatable, Sendable {
    package var command: [String]
    package var tty: Bool
    package var interactive: Bool
    package var columns: UInt16
    package var rows: UInt16

    /// A terminal's classic size, for commands that get no real one.
    package static let defaultColumns: UInt16 = 80
    package static let defaultRows: UInt16 = 24

    package init(
        command: [String], tty: Bool, interactive: Bool, columns: UInt16 = ExecRequest.defaultColumns,
        rows: UInt16 = ExecRequest.defaultRows
    ) {
        self.command = command
        self.tty = tty
        self.interactive = interactive
        self.columns = columns
        self.rows = rows
    }

    /// The flags byte, columns and rows, the fallback user as a `UInt16` length and UTF-8 (empty for none), then the
    /// argument count as a `UInt16` and each argument as a `UInt32` length and UTF-8.
    func startPayload(fallbackUser: String?) throws -> Data {
        guard !command.isEmpty, command.count <= Int(UInt16.max) else {
            throw HangarError("Give hangar exec a command to run.")
        }
        let user = Data((fallbackUser ?? "").utf8)
        guard user.count <= Int(UInt16.max) else { throw HangarError("The VM's account name is too long.") }

        var payload = Data([(tty ? 1 : 0) | (interactive ? 2 : 0)])
        payload.append(Data(bigEndian: columns))
        payload.append(Data(bigEndian: rows))
        payload.append(Data(bigEndian: UInt16(user.count)))
        payload.append(user)
        payload.append(Data(bigEndian: UInt16(command.count)))
        for argument in command {
            let bytes = Data(argument.utf8)
            payload.append(Data(bigEndian: UInt32(bytes.count)))
            payload.append(bytes)
        }

        guard payload.count <= ExecFrame.maximumPayload else {
            throw HangarError("The command is too long for hangar exec; put it in a script and run that.")
        }
        return payload
    }
}
