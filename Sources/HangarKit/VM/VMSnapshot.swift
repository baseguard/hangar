import Darwin
import Foundation

package struct VMSnapshot: Hashable, Identifiable, Sendable {
    package let url: URL
    package let createdAt: Date

    init(url: URL) {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        createdAt = attributes?[.creationDate] as? Date ?? .distantPast
    }

    package var name: String { url.lastPathComponent }
    package var id: String { name }

    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var nvramURL: URL { url.appendingPathComponent("nvram.bin") }
    var configURL: URL { url.appendingPathComponent("config.json") }
}
