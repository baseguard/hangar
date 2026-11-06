import Darwin
import Foundation
import HangarSupport

enum ControlSocket {
    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw HangarError("Socket path too long: \(path)")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        return address
    }

    static let maximumLineBytes = 4096

    // Nil for a longer line, so its first part is never read as a whole message.
    static func readLine(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1, byte != UInt8(ascii: "\n") else { break }
            guard data.count < maximumLineBytes else { return nil }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeAll(_ fd: Int32, _ string: String) throws {
        var bytes = Array(string.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written >= 0 else { throw HangarError(errno: errno, "Could not send a message to the VM") }
            guard written > 0 else { throw HangarError("Could not send a message to the VM: the connection closed.") }
            bytes = bytes.dropFirst(written)
        }
    }

    static func writeMessage(_ message: some Encodable, to fd: Int32) throws {
        let data = try encoder.encode(message)
        try writeAll(fd, String(decoding: data, as: UTF8.self) + "\n")
    }

    static func decodeMessage<Message: Decodable>(_ type: Message.Type, from line: String) throws -> Message {
        try JSONDecoder().decode(type, from: Data(line.utf8))
    }

    // Sorted keys and no pretty printing keep each message on one line.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
