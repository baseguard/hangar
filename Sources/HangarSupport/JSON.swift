import Foundation

package enum JSON {
    package static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    package static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    package static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    package static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    package static func refuseUnknownKeys(in fields: [String: Any], known: Set<String>, of what: String) throws {
        if let unknown = fields.keys.sorted().first(where: { !known.contains($0) }) {
            throw HangarError("\(what) has a field Hangar doesn't know: '\(unknown)'.")
        }
    }

    package static func problem(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey]) -> String { keys.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context): return "missing '\(path(context.codingPath + [key]))'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "'\(path(context.codingPath))' has the wrong type"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "'\(path(context.codingPath))' is invalid"
        @unknown default: return "not valid JSON"
        }
    }
}
