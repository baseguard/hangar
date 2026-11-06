import ArgumentParser
import Darwin
import Foundation
import HangarKit
import HangarSupport

struct Copy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files and folders between this Mac and a running VM.",
        discussion: """
            Examples:
              hangar cp report.pdf deb:/home/dev/
                  Copy a file into a folder in the VM.
              hangar cp deb:/var/log/app.log .
                  Copy a file from the VM into this folder.
              hangar cp deb:/home/dev/project - > project.tar
                  Write a folder in the VM as a tar archive.
            A path in the VM starts with the VM's name and a colon. A copy into an
            existing folder keeps its name; otherwise it takes the name you give.
            Files from the VM replace files on this Mac at that path, and
            folders are only added to. Links and special files are left out.
            With "-" the tar archive goes to or from this terminal unchecked.
            It runs as the user at the VM's screen and needs Hangar's agent 19.
            """
    )

    @Argument(help: ArgumentHelp("What to copy: a path here, or <vm>:<path>.", valueName: "source"))
    var source: String

    @Argument(
        help: ArgumentHelp("Where to: a path here, <vm>:<path>, or - for a tar archive.", valueName: "destination"))
    var destination: String

    func validate() throws {
        switch (Place(source), Place(destination)) {
        case (.guest, .guest): throw ValidationError("Copy between this Mac and a VM; one side must be here.")
        case (.guest, _), (_, .guest): return
        default: throw ValidationError("Name the VM's side as <vm>:<path>, like deb:/home/dev.")
        }
    }

    func run() throws {
        let errors: GuestCopy.ErrorOutput = { try? FileHandle.standardError.write(contentsOf: $0) }
        let from = Place(source)
        let to = Place(destination)
        guard let bundle = from.bundle ?? to.bundle else { return }
        try GuestCopy.checkAgent(of: bundle, needs: GuestSetup.firstCopyAgentVersion, for: "hangar cp")

        switch (from, to) {
        case (.here(let path), .guest(let bundle, let guestPath)):
            let skipped = try GuestCopy.copyIn(URL(userPath: path), to: guestPath, in: bundle, errors: errors)
            report(skipped: skipped)
            print("Copied into '\(bundle.name)'.")
        case (.terminal, .guest(let bundle, let guestPath)):
            try GuestCopy.streamIn(from: STDIN_FILENO, to: guestPath, in: bundle, errors: errors)
        case (.guest(let bundle, let guestPath), .here(let path)):
            let (parent, name) = try Self.placement(of: guestPath, at: URL(userPath: path))
            let outcome = try GuestCopy.copyOut(guestPath, into: parent, as: name, in: bundle, errors: errors)
            report(skipped: outcome.skipped)
            print("Copied \(outcome.files) file\(outcome.files == 1 ? "" : "s") from '\(bundle.name)'.")
        case (.guest(let bundle, let guestPath), .terminal):
            try GuestCopy.streamOut(guestPath, to: STDOUT_FILENO, in: bundle, errors: errors)
        default:
            return
        }
    }

    /// Where a copy from the VM goes: into an existing folder under the VM item's name, otherwise
    /// under the name given. The Mac picks it, never the VM.
    private static func placement(of guestPath: String, at local: URL) throws -> (parent: URL, name: String) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isFolder), isFolder.boolValue {
            return (local, try lastName(of: guestPath))
        }
        guard !local.hasDirectoryPath else { throw HangarError("There is no folder \(local.path) on this Mac.") }

        let parent = local.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw HangarError("There is no folder \(parent.path) on this Mac.")
        }
        return (parent, local.lastPathComponent)
    }

    /// The last part of a path in the VM; Windows paths use "\" as well as "/".
    private static func lastName(of guestPath: String) throws -> String {
        let parts = guestPath.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard let last = parts.last, !(parts.count == 1 && last.hasSuffix(":")) else {
            throw HangarError("Name a file or folder in the VM, not its top folder.")
        }
        guard last != ".", last != ".." else { throw HangarError("Name a file or folder in the VM, not . or ..") }
        return String(last)
    }

    private func report(skipped: Int) {
        guard skipped > 0 else { return }
        printError("Skipped \(skipped) link\(skipped == 1 ? "" : "s") or special file\(skipped == 1 ? "" : "s").")
    }
}

/// One side of a copy: a path on this Mac, this terminal's tar stream, or a path in a VM.
private enum Place {
    case here(String)
    case terminal
    case guest(VMBundle, String)

    /// `<vm>:<path>` when what's before the first colon names a VM; a Windows path keeps its own colon after it.
    init(_ text: String) {
        if text == "-" {
            self = .terminal
            return
        }
        if let colon = text.firstIndex(of: ":") {
            let name = String(text[..<colon])
            if VMLibrary.isValidName(name), let bundle = try? VMLibrary.bundle(named: name) {
                self = .guest(bundle, String(text[text.index(after: colon)...]))
                return
            }
        }
        self = .here(text)
    }

    var bundle: VMBundle? {
        guard case .guest(let bundle, _) = self else { return nil }
        return bundle
    }
}
