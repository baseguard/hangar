import Foundation
import HangarSupport
import Testing

/// A mistake in a command's arguments prints that command's usage, not the root command's, and exits 64.
@Suite(.temporaryHangarHome)
struct UsageErrorTests {
    private static let usageError: Int32 = 64

    @Test(arguments: [
        (["network", "set", "--subnet", "10.0.0.1/8"], "Use the host address with a prefix between /16 and /29"),
        (["export", "box", "ghcr.io/acme/ci-linux"], "'ghcr.io/acme/ci-linux' is not an image like"),
        (
            ["export", "box", "ghcr.io/acme/ci-linux@sha256:" + String(repeating: "0", count: 64)],
            "Give the place to push with a tag"
        ),
        (["export", "box", "box.tar", "--insecure"], "--chunk-size and --insecure go with a registry."),
        (["traffic", "box", "-n", "99999999999"], "--count must be between 1 and 100000."),
        (["logs", "box", "-n", "0"], "--count must be between 1 and 100000."),
        (["set", "box"], "Give a setting to change, like --cpu 4."),
        (["set", "box", "--iso", "linux.iso", "--no-iso"], "--iso and --no-iso don't go together."),
        (["exec", "box"], "Give the command to run after the VM's name."),
        (["exec", "box", "--"], "Give the command to run after the VM's name."),
    ])
    func aMistakeShowsTheCommandsOwnUsage(arguments: [String], message: String) throws {
        let result = try HangarCommand.run(arguments)

        #expect(result.status == Self.usageError)
        #expect(result.error.hasPrefix("Error: \(message)"))
        #expect(result.error.contains("Usage: hangar \(arguments[0])"))
    }
}
