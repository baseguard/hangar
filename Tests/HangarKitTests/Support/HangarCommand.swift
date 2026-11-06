import Foundation
import HangarSupport

/// The `hangar` command line that the scheme builds next to this test bundle, run in the test's Hangar home
/// with no terminal, the way someone's script would run it.
enum HangarCommand {
    struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    private final class TestBundle {}

    static func run(_ arguments: [String], input: String? = nil) throws -> Result {
        let products = Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent()
        let outputURL = HangarPaths.home.appendingPathComponent("command.out")
        let errorURL = HangarPaths.home.appendingPathComponent("command.err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let process = Process()
        process.executableURL = products.appendingPathComponent("HangarCLI.app/Contents/MacOS/hangar")
        process.arguments = arguments
        process.environment = ["HANGAR_HOME": HangarPaths.home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = try input.map(inputFile) ?? FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorURL)
        try process.run()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus, output: try String(contentsOf: outputURL, encoding: .utf8),
            error: try String(contentsOf: errorURL, encoding: .utf8))
    }

    private static func inputFile(_ text: String) throws -> FileHandle {
        let url = HangarPaths.home.appendingPathComponent("command.in")
        try Data(text.utf8).write(to: url)
        return try FileHandle(forReadingFrom: url)
    }
}
