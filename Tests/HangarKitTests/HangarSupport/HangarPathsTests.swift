import Foundation
import Testing

@testable import HangarSupport

struct HangarPathsTests {
    @Test func aHomeOpenToOthersIsClosedEvenWhenItAppearsLater() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("hangar-home-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: home) }

        HangarPaths.securePrivateHome(home)
        let isCreated = manager.fileExists(atPath: home.path)
        try manager.createDirectory(
            at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        HangarPaths.securePrivateHome(home)

        #expect(!isCreated)
        let mode = try manager.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
