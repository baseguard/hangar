import Foundation
import Synchronization

final class FinishedChunks: Sendable {
    let url: URL
    private let digests: Mutex<Set<String>>

    init(url: URL) {
        self.url = url
        digests = Mutex(Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []))
    }

    func contains(_ digest: String) -> Bool { digests.withLock { $0.contains(digest) } }

    func reset() {
        digests.withLock { $0 = [] }
        try? FileManager.default.removeItem(at: url)
    }

    func add(_ digest: String) throws {
        let sorted = digests.withLock { digests -> [String] in
            digests.insert(digest)
            return digests.sorted()
        }
        try JSONEncoder().encode(sorted).write(to: url, options: .atomic)
    }
}
