import Foundation

enum BlobStart: Sendable {
    case whole
    case partial(start: Int64, total: Int64)
    case unexpected

    init(_ response: HTTPURLResponse) {
        let range = response.value(forHTTPHeaderField: "Content-Range")?.wholeMatch(
            of: /bytes ([0-9]+)-[0-9]+\/([0-9]+)/)
        switch (response.statusCode, range.flatMap { Int64($0.1) }, range.flatMap { Int64($0.2) }) {
        case (200, _, _):
            self = .whole
        case (206, let start?, let total?):
            self = .partial(start: start, total: total)
        default:
            self = .unexpected
        }
    }
}

protocol BlobSource: Sendable {
    func manifest(digest: String) async throws -> Data
    func blob(_ digest: String, limit: Int) async throws -> Data
    func streamBlob(
        _ digest: String, from start: Int64, begin: @escaping @Sendable (BlobStart) throws -> Void,
        consume: @escaping @Sendable (Data) throws -> Void) async throws
}
