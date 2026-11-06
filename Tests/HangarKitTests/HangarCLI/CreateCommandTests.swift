import Foundation
import HangarSupport
import Testing

/// Swift 6.4 once turned every `hangar create` mistake into "Give --os.", so each mistake is checked by its message.
@Suite(.temporaryHangarHome)
struct CreateCommandTests {
    private static let usageError: Int32 = 64

    private var vms: URL { HangarPaths.home.appendingPathComponent("vms") }

    @Test func createWithoutAnOSAsksForOne() throws {
        let result = try HangarCommand.run(["create", "box"])

        #expect(result.status == Self.usageError)
        #expect(result.error.hasPrefix("Error: Give --os or --template.\n"))
    }

    @Test(arguments: [
        (
            ["--os", "linux", "--user", "dev", "--password-stdin"],
            "On Linux, --user and --password-stdin go with a cloud image (--disk-image) or --image."
        ),
        (["--os", "linux", "--no-remote-desktop"], "--no-remote-desktop is for Windows guests."),
        (["--os", "windows"], "Windows needs --iso (a Windows 11 Arm64 ISO) or --image."),
        (["--os", "windows", "--disk-image", "disk.raw"], "--disk-image is for Linux guests."),
        (["--os", "macos", "--iso", "linux.iso"], "--iso is for Linux and Windows guests."),
        (["--os", "macos", "--password-stdin"], "--password-stdin goes with --user."),
        (
            ["--os", "macos", "--user", "dev"],
            "--user needs a password: run interactively to be asked, or pass --password-stdin."
        ),
        (["--os", "linux", "--cpu", "4096"], "--cpu must be between 1 and"),
        (["--os", "linux", "--allow-write-shares"], "--allow-write-shares goes with --template."),
        (
            ["--os", "linux", "--image", "fedora"],
            "--image fedora isn't an image in a registry or a .tar file; Hangar's own Linux images are debian and ubuntu."
        ),
    ])
    func eachMistakeGetsItsOwnMessageAndCreatesNothing(options: [String], message: String) throws {
        let result = try HangarCommand.run(["create", "box"] + options)

        #expect(result.status == Self.usageError)
        #expect(result.error.hasPrefix("Error: \(message)"))
        #expect(!FileManager.default.fileExists(atPath: vms.appendingPathComponent("box").path))
    }

    /// A template someone sends could share the user's home read-write; its author chose that, not the user.
    @Test func aTemplateSharingAFolderReadWriteNeedsTheUsersSayForIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = HangarPaths.home.appendingPathComponent("share.hangarvm")
        let json = """
            {"os": "linux", "from": {"cloudImage": "debian"},
             "sharedFolders": [{"name": "src", "path": "\(folder.path)", "readOnly": false}]}
            """
        try Data(json.utf8).write(to: template)

        let result = try HangarCommand.run(["create", "box", "--template", template.path])

        #expect(result.status == Self.usageError)
        #expect(result.error.hasPrefix("Error: The template shares \(folder.path) read-write"))
        #expect(result.error.contains("--allow-write-shares"))
        #expect(!FileManager.default.fileExists(atPath: vms.appendingPathComponent("box").path))
    }

    @Test func aBadNameIsRefusedBeforeAnythingElse() throws {
        let result = try HangarCommand.run(["create", "bad/name", "--os", "linux"])

        #expect(result.status == 1)
        #expect(result.error.hasPrefix("Error: Invalid VM name 'bad/name'."))
    }

    @Test func listAndStopSpeakPlainlyInAnEmptyLibrary() throws {
        let list = try HangarCommand.run(["list"])
        let stop = try HangarCommand.run(["stop", "nosuch"])
        let unknown = try HangarCommand.run(["frobnicate"])

        #expect(list.status == 0)
        #expect(list.output == "No VMs yet. Create one with `hangar create`.\n")
        #expect(stop.status == 1)
        #expect(stop.error == "Error: No VM named 'nosuch'. See `hangar list`.\n")
        #expect(unknown.status == Self.usageError)
        #expect(unknown.error.hasPrefix("Error: Unexpected argument 'frobnicate'"))
    }
}
