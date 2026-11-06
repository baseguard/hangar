import Foundation

package enum HostSniffer {
    package enum Result: Equatable {
        case needMore
        case unknown
        case tls(serverName: String?)
        /// A request line; `HTTPStream` reads the head that follows.
        case http
    }

    package struct Request: Equatable {
        package let method: String
        package let host: String?
        package let path: String
        package let contentLength: Int?
        package let isChunked: Bool
        // Both an Upgrade field and a Connection field naming it, as RFC 9110 asks for.
        package let upgrades: Bool
    }

    /// A TLS record holds at most 16 KiB after its 5-byte header, so a ClientHello that needs more isn't one.
    package static let limit = 16 * 1024 + 5
    package static let maximumHead = 8192
    package static let carriageReturn = UInt8(ascii: "\r")
    package static let lineFeed = UInt8(ascii: "\n")

    package static func sniff(_ bytes: [UInt8]) -> Result {
        guard let first = bytes.first else { return .needMore }
        if first == 0x16 { return tls(bytes) }
        return http(bytes)
    }

    package static func headLength(_ bytes: ArraySlice<UInt8>) -> Int? {
        let end = bytes.startIndex + min(bytes.count, maximumHead + 4)
        var index = bytes.startIndex
        while index + 3 < end {
            if bytes[index] == carriageReturn, bytes[index + 1] == lineFeed, bytes[index + 2] == carriageReturn,
                bytes[index + 3] == lineFeed
            {
                return index + 4 - bytes.startIndex
            }
            index += 1
        }
        return nil
    }

    package static func request(_ head: ArraySlice<UInt8>) -> Request? {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let line = lines.first, isRequestLine(line) else { return nil }

        let parts = line.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let header = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { withoutPort($0.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
        var host = header
        var path = target

        if method == "CONNECT" {
            host = withoutPort(target)
            path = ""
        } else if target.contains("://"), let url = URL(string: target), let absolute = url.host {
            // Like two Host fields: a server that ignores RFC 9112 would go by the field, not the target.
            if let header, header.lowercased() != absolute.lowercased() { return nil }
            host = absolute
            path = url.path.isEmpty ? "/" : url.path
        }

        // Only HTTP/1.0 and 1.1 are read for their host; the rules see a request of another version as unnamed.
        if !(parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0") { host = nil }
        guard let fields = framingFields(lines.dropFirst()) else { return nil }

        let name = host.map { Packet.printable($0.utf8).lowercased() }

        return Request(
            method: method, host: name?.isEmpty == false ? name : nil, path: Packet.printable(path.utf8.prefix(512)),
            contentLength: fields.contentLength, isChunked: fields.isChunked,
            upgrades: fields.hasUpgrade && fields.connectionUpgrades)
    }

    private struct FramingFields {
        var hosts = 0
        var contentLength: Int?
        var isChunked = false
        var hasUpgrade = false
        var connectionUpgrades = false
    }

    /// Nil for framing that two parsers could read differently: two Host fields, two lengths, or both kinds.
    private static func framingFields(_ lines: ArraySlice<String>) -> FramingFields? {
        var fields = FramingFields()

        for field in lines {
            let lower = field.lowercased()
            if lower.hasPrefix("host:") {
                fields.hosts += 1
            } else if lower.hasPrefix("content-length:") {
                guard fields.contentLength == nil,
                    let length = Int(lower.dropFirst(15).trimmingCharacters(in: .whitespaces)), length >= 0
                else { return nil }
                fields.contentLength = length
            } else if lower.hasPrefix("transfer-encoding:") {
                guard !fields.isChunked, lower.dropFirst(18).trimmingCharacters(in: .whitespaces) == "chunked" else {
                    return nil
                }
                fields.isChunked = true
            } else if lower.hasPrefix("upgrade:") {
                fields.hasUpgrade = true
            } else if lower.hasPrefix("connection:") {
                let tokens = lower.dropFirst(11).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                fields.connectionUpgrades = fields.connectionUpgrades || tokens.contains("upgrade")
            }
        }

        guard fields.hosts <= 1, !(fields.isChunked && fields.contentLength != nil) else { return nil }
        return fields
    }

    private static func isRequestLine(_ line: String) -> Bool {
        line.wholeMatch(of: /[A-Za-z]{1,20} [^ ]{1,8000} HTTP\/[0-9]\.[0-9]/) != nil
    }

    private static func tls(_ bytes: [UInt8]) -> Result {
        switch hello(bytes) {
        case .decided(let result):
            return result
        case .complete(let handshake, let end):
            return .tls(serverName: serverName(handshake, end: end))
        }
    }

    /// The application protocols (ALPN) a complete ClientHello offers, like "h2" and "http/1.1", in its order.
    package static func offeredProtocols(_ bytes: [UInt8]) -> [String] {
        guard case .complete(let handshake, let end) = hello(bytes),
            let data = extensionData(type: 16, in: handshake, end: end), data.count >= 2
        else { return [] }

        var protocols: [String] = []
        let listEnd = min(data.upperBound, data.lowerBound + 2 + Int(Packet.readUInt16(handshake, at: data.lowerBound)))
        var offset = data.lowerBound + 2
        while offset < listEnd {
            let nameEnd = offset + 1 + Int(handshake[offset])
            guard nameEnd <= listEnd else { break }
            protocols.append(Packet.printable(handshake[(offset + 1)..<nameEnd]))
            offset = nameEnd
        }
        return protocols
    }

    private enum Hello {
        /// Not a whole ClientHello: what `sniff` says about these bytes.
        case decided(Result)
        /// The handshake message, from its records, and where the ClientHello in it ends.
        case complete(handshake: [UInt8], end: Int)
    }

    private static func hello(_ bytes: [UInt8]) -> Hello {
        if bytes.count >= 2, bytes[1] != 3 { return .decided(.unknown) }
        var handshake: [UInt8] = []
        var offset = 0
        var interrupted = false

        while offset + 5 <= bytes.count {
            guard bytes[offset] == 0x16, bytes[offset + 1] == 3 else {
                interrupted = true
                break
            }

            let end = offset + 5 + Int(Packet.readUInt16(bytes, at: offset + 3))
            handshake += bytes[(offset + 5)..<min(end, bytes.count)]
            offset = end
        }

        let incomplete: Result = interrupted || bytes.count >= limit ? .tls(serverName: nil) : .needMore
        guard handshake.count >= 4 else { return .decided(incomplete) }
        guard handshake[0] == 1 else { return .decided(.tls(serverName: nil)) }

        let helloEnd = 4 + (Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3]))
        guard handshake.count >= helloEnd else { return .decided(incomplete) }

        return .complete(handshake: handshake, end: helloEnd)
    }

    private static func serverName(_ bytes: [UInt8], end: Int) -> String? {
        guard let data = extensionData(type: 0, in: bytes, end: end), data.count >= 5, bytes[data.lowerBound + 2] == 0
        else { return nil }
        let nameLength = Int(Packet.readUInt16(bytes, at: data.lowerBound + 3))
        let nameStart = data.lowerBound + 5
        guard nameStart + nameLength <= data.upperBound, nameLength > 0 else { return nil }
        return Packet.printable(bytes[nameStart..<(nameStart + nameLength)]).lowercased()
    }

    /// Where the data of the ClientHello's extension `type` lies in `bytes`, or nil when it has none.
    private static func extensionData(type wanted: UInt16, in bytes: [UInt8], end: Int) -> Range<Int>? {
        var offset = 4 + 2 + 32
        guard offset < end else { return nil }

        offset += 1 + Int(bytes[offset])
        guard offset + 2 <= end else { return nil }

        offset += 2 + Int(Packet.readUInt16(bytes, at: offset))
        guard offset < end else { return nil }

        offset += 1 + Int(bytes[offset])
        guard offset + 2 <= end else { return nil }

        let extensionsEnd = min(end, offset + 2 + Int(Packet.readUInt16(bytes, at: offset)))
        offset += 2

        while offset + 4 <= extensionsEnd {
            let type = Packet.readUInt16(bytes, at: offset)
            let length = Int(Packet.readUInt16(bytes, at: offset + 2))
            let data = offset + 4
            guard data + length <= extensionsEnd else { return nil }
            if type == wanted { return data..<(data + length) }
            offset = data + length
        }

        return nil
    }

    private static func http(_ bytes: [UInt8]) -> Result {
        guard let lineEnd = bytes.firstIndex(of: 10) else {
            let textual = bytes.allSatisfy { (0x20...0x7e).contains($0) }
            return textual && bytes.count < maximumHead ? .needMore : .unknown
        }

        let line = String(decoding: bytes[..<lineEnd], as: UTF8.self).trimmingCharacters(
            in: CharacterSet(charactersIn: "\r"))
        return isRequestLine(line) ? .http : .unknown
    }

    private static func withoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        return String(host.split(separator: ":", maxSplits: 1).first ?? "")
    }
}
