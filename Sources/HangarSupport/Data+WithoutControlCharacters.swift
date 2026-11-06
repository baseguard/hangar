import Foundation

extension Data {
    /// Text from a guest or a server, with each control character as "?", so it can't put escape sequences on the
    /// user's terminal or into an alert. Line breaks and tabs stay.
    package var withoutControlCharacters: Data {
        Data(map { Self.isControlCharacter($0) ? UInt8(ascii: "?") : $0 })
    }

    private static func isControlCharacter(_ byte: UInt8) -> Bool {
        let isLayout = byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t")
        return (byte < 0x20 && !isLayout) || byte == 0x7F
    }
}
