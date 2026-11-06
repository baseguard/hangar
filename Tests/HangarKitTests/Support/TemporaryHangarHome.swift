import Foundation
import HangarSupport
import Testing

struct TemporaryHangarHome: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let home = URL(fileURLWithPath: "/tmp/hangar-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try await HangarPaths.$homeOverride.withValue(home) {
            try await function()
        }
    }
}

extension Trait where Self == TemporaryHangarHome {
    static var temporaryHangarHome: Self { TemporaryHangarHome() }
}
