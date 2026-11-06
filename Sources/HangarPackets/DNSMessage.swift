import Darwin
import Foundation
import HangarSupport

package struct DNSMessage {
    package struct Question {
        package let name: String
        package let type: UInt16
    }

    package struct Answer {
        package let ttl: UInt32
        package let address: UInt32?
        package let address6: String?
        package let alias: String?

        init(ttl: UInt32, address: UInt32? = nil, address6: String? = nil, alias: String? = nil) {
            self.ttl = ttl
            self.address = address
            self.address6 = address6
            self.alias = alias
        }
    }

    static let typeA: UInt16 = 1
    static let typeNS: UInt16 = 2
    static let typeCNAME: UInt16 = 5
    static let typeSOA: UInt16 = 6
    static let typePTR: UInt16 = 12
    static let typeMX: UInt16 = 15
    static let typeTXT: UInt16 = 16
    static let typeAAAA: UInt16 = 28
    static let typeSRV: UInt16 = 33
    package static let typeSVCB: UInt16 = 64
    package static let typeHTTPS: UInt16 = 65
    static let typeANY: UInt16 = 255
    package static let serverFailure: UInt8 = 2
    package static let nameError: UInt8 = 3
    package static let refused: UInt8 = 5

    /// In the flags' first byte: the response bit, and the query's bits a refusal keeps (opcode and RD; not AA or TC).
    private static let responseBit: UInt8 = 0x80
    private static let keptQueryFlags: UInt8 = 0x79
    /// In the flags' second byte: recursion available, and the response code.
    private static let recursionAvailable: UInt8 = 0x80
    private static let responseCodeMask: UInt8 = 0x0f
    /// The answer, authority and additional counts, which a refusal zeroes.
    private static let recordCounts = 6..<12

    package let id: UInt16
    let flags: UInt16
    /// Resolvers ask one question per message, so a message with any other number isn't read.
    package let question: Question
    package let answers: [Answer]
    let questionsEnd: Int

    package var isResponse: Bool { flags & 0x8000 != 0 }
    package var responseCode: UInt8 { UInt8(flags & 0x000f) }

    package init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }

        id = Packet.readUInt16(bytes, at: 0)
        flags = Packet.readUInt16(bytes, at: 2)
        let questionCount = Int(Packet.readUInt16(bytes, at: 4))
        let answerCount = Int(Packet.readUInt16(bytes, at: 6))
        guard questionCount == 1 else { return nil }

        guard let name = Self.readName(bytes, at: 12), name.end + 4 <= bytes.count else { return nil }
        question = Question(name: name.name, type: Packet.readUInt16(bytes, at: name.end))
        var offset = name.end + 4
        questionsEnd = offset
        var answers: [Answer] = []

        for _ in 0..<min(answerCount, 64) {
            guard let end = Self.readName(bytes, at: offset)?.end, end + 10 <= bytes.count else { break }
            let type = Packet.readUInt16(bytes, at: end)
            let ttl = Packet.readUInt32(bytes, at: end + 4)
            let length = Int(Packet.readUInt16(bytes, at: end + 8))
            let data = end + 10
            guard data + length <= bytes.count else { break }
            answers.append(Self.readAnswer(type: type, ttl: ttl, in: bytes, at: data, length: length))
            offset = data + length
        }

        self.answers = answers
    }

    /// Only what Hangar uses: an IPv4 or IPv6 address, or the name a CNAME or SRV record points to.
    private static func readAnswer(type: UInt16, ttl: UInt32, in bytes: [UInt8], at data: Int, length: Int) -> Answer {
        switch type {
        case typeA where length == 4:
            Answer(ttl: ttl, address: Packet.readUInt32(bytes, at: data))
        case typeAAAA where length == 16:
            Answer(ttl: ttl, address6: formatIPv6(Array(bytes[data..<(data + 16)])))
        case typeCNAME:
            Answer(ttl: ttl, alias: readName(bytes, at: data)?.name)
        case typeSRV where length > 6:
            Answer(ttl: ttl, alias: readName(bytes, at: data + 6)?.name)
        default:
            Answer(ttl: ttl)
        }
    }

    static func readName(_ bytes: [UInt8], at start: Int) -> (name: String, end: Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        var length = 0

        while true {
            guard offset < bytes.count else { return nil }
            let size = Int(bytes[offset])
            if size == 0 {
                break
            }
            if size & 0xc0 == 0xc0 {
                guard offset + 1 < bytes.count, jumps < 16 else { return nil }
                if end == nil { end = offset + 2 }
                offset = (size & 0x3f) << 8 | Int(bytes[offset + 1])
                jumps += 1
                continue
            }
            guard size <= 63, offset + 1 + size <= bytes.count else { return nil }
            length += size + 1
            guard length <= 255 else { return nil }
            labels.append(Packet.printable(bytes[(offset + 1)...(offset + size)]))
            offset += 1 + size
        }

        return (labels.joined(separator: ".").lowercased(), end ?? offset + 1)
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String? {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return bytes.withUnsafeBytes { raw in
            inet_ntop(AF_INET6, raw.baseAddress, &text, socklen_t(text.count)) != nil
                ? String(nulTerminated: text) : nil
        }
    }

    package static func refusal(to query: [UInt8], code: UInt8) -> [UInt8]? {
        guard let message = DNSMessage(query), !message.isResponse else { return nil }
        var reply = Array(query[0..<message.questionsEnd])
        reply[2] = responseBit | (query[2] & keptQueryFlags)
        reply[3] = recursionAvailable | (code & responseCodeMask)
        for index in recordCounts { reply[index] = 0 }
        return reply
    }

    package static func typeName(_ type: UInt16) -> String {
        switch type {
        case typeA: "A"
        case typeNS: "NS"
        case typeCNAME: "CNAME"
        case typeSOA: "SOA"
        case typePTR: "PTR"
        case typeMX: "MX"
        case typeTXT: "TXT"
        case typeAAAA: "AAAA"
        case typeSRV: "SRV"
        case typeSVCB: "SVCB"
        case typeHTTPS: "HTTPS"
        case typeANY: "ANY"
        default: "TYPE\(type)"
        }
    }
}
