/// One line from the MCP client: a message, or a line too long to read.
enum MCPLine: Equatable, Sendable {
    case message(String)
    case tooLong
}

/// Cuts the client's input into lines, keeping at most `maximumLength` bytes of each, so one endless line can't fill
/// this Mac's memory.
struct MCPLineSplitter {
    static let maximumLength = 1 << 20

    private var line: [UInt8] = []
    private var isTooLong = false

    /// The line that `byte` ends, when it is a line break that ends one.
    mutating func add(_ byte: UInt8) -> MCPLine? {
        guard byte == UInt8(ascii: "\n") else {
            keep(byte)
            return nil
        }
        return endLine()
    }

    /// The last line, when the input ended without a line break after it.
    mutating func finish() -> MCPLine? {
        endLine()
    }

    private mutating func keep(_ byte: UInt8) {
        if line.count < Self.maximumLength {
            line.append(byte)
        } else {
            isTooLong = true
        }
    }

    /// Blank lines are no messages, so they get no answer.
    private mutating func endLine() -> MCPLine? {
        defer {
            line.removeAll(keepingCapacity: true)
            isTooLong = false
        }
        if isTooLong { return .tooLong }

        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard !line.isEmpty else { return nil }
        return .message(String(decoding: line, as: UTF8.self))
    }
}
