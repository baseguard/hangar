import Foundation
import HangarKit
import HangarSupport
import SwiftUI

struct CommandLineSettings: View {
    private static let installPath = "/usr/local/bin/hangar"

    @State private var message: String?
    @State private var installed = FileManager.default.fileExists(atPath: CommandLineSettings.installPath)

    var body: some View {
        Form {
            Section {
                LabeledContent("hangar") {
                    Text(HangarExecutable.url.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent {
                    Button(installed ? "Reinstall…" : "Install…", action: install)
                } label: {
                    Text(installed ? "Installed in /usr/local/bin" : "Not in /usr/local/bin")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Command-Line Tool")
            } footer: {
                Text(
                    "The command line and the app share the same VMs: hangar list, hangar run <vm>, hangar traffic <vm> -f…"
                )
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        let source = HangarExecutable.url.resolvingSymlinksInPath().path
        if let refusal = Self.installRefusal(linkingTo: source) {
            message = refusal
            return
        }

        let installPath = Self.installPath
        let folder = (installPath as NSString).deletingLastPathComponent
        let command = [
            "/bin/sh", "-c", "mkdir -p \"$1\" && ln -sfh \"$2\" \"$3\"", "hangar", folder, source, installPath,
        ]
        message = "Installing…"
        Task {
            let result = await runInBackground { () -> String in
                do {
                    try ProcessUtil.runAsAdministrator(command)
                    return "Installed \(installPath)."
                } catch {
                    return error.localizedDescription
                }
            }
            message = result
            installed = FileManager.default.fileExists(atPath: installPath)
        }
    }

    /// Why the link can't be installed, or nil. Root installs it for every user of this Mac, so it must point into
    /// a copy only an administrator can change, and must not replace another program.
    private static func installRefusal(linkingTo source: String) -> String? {
        // The Applications folder also rules out a disk image or a translocated copy, which go away.
        guard source.hasPrefix("/Applications/") else {
            return "Move Hangar to the Applications folder first, then install the command-line tool."
        }
        guard isFreeForHangar(installPath) else {
            return "\(installPath) isn't Hangar's command. Remove it first, then install the command-line tool."
        }
        return nil
    }

    /// Free when nothing is there, or when it is a link into a Hangar.app, which the install replaces.
    private static func isFreeForHangar(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT }
        let isLink = info.st_mode & S_IFMT == S_IFLNK
        guard isLink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return false
        }
        return target.hasSuffix("/" + HangarExecutable.bundledPath)
    }
}
