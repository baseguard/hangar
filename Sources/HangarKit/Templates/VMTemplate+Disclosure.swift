import Foundation
import HangarSupport

/// A folder the template names that this Mac won't share, with the reason as a sentence.
package struct SkippedFolder: Hashable, Sendable {
    package let folder: SharedFolder
    package let reason: String
}

/// A template someone sends may share any folder of this Mac and run commands in the VM; its author chose them, so
/// the app and `hangar create` show all of it before the VM is made.
extension VMTemplate {
    /// The template's shared folders as this Mac shares them, with `~` expanded, and those it won't share: missing,
    /// not a folder, or one that holds Hangar's own library read-write.
    package func sharedFoldersOnThisMac() -> (shared: [SharedFolder], skipped: [SkippedFolder]) {
        var shared: [SharedFolder] = []
        var skipped: [SkippedFolder] = []
        for folder in sharedFolders ?? [] {
            do {
                shared.append(try SharedFolder.make(path: folder.path, name: folder.name, readOnly: folder.readOnly))
            } catch {
                skipped.append(SkippedFolder(folder: folder, reason: error.localizedDescription))
            }
        }
        return (shared, skipped)
    }

    /// What a VM made from this template gets from it, one line each: every folder in `shared`, the traffic rules,
    /// every setup command as written and, last because it can be long, the cloud-init user data under a label.
    package func disclosure(sharing shared: [SharedFolder]) -> [String] {
        var lines = shared.map(Self.sharingLine)
        if let trafficDescription { lines.append("Traffic: \(trafficDescription)") }
        for command in shownSetupCommands { lines.append("Runs in the VM on its first start: \(command)") }
        if !shownCloudInitLines.isEmpty {
            lines.append("Runs as root on its first start (cloud-init):")
            for line in shownCloudInitLines { lines.append("  \(line)") }
        }
        return lines
    }

    private static func sharingLine(_ folder: SharedFolder) -> String {
        let access = folder.readOnly ? "read-only" : "read-write"
        return "Shares \(printable(folder.path)) with the VM, \(access), as \(folder.name)"
    }

    /// The traffic mode, what the VM can reach and the hosts it is allowed.
    package var trafficDescription: String? {
        guard let traffic else { return nil }
        guard !traffic.allowed.isEmpty else { return traffic.summary }
        return "\(traffic.summary) Allowed hosts: \(traffic.allowed.joined(separator: ", "))."
    }

    package var shownSetupCommands: [String] {
        (setup ?? []).map(Self.printable)
    }

    /// The cloud-init user data as written, split at its line breaks so each line can go through `printable`.
    package var shownCloudInitLines: [String] {
        guard let cloudInit else { return [] }
        var lines = cloudInit.components(separatedBy: "\n").map(Self.printable)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Escape sequences, line breaks and right-to-left marks in a command could hide or rewrite the very lines that
    /// show it, so each shows as a `\u{…}` code instead.
    package static func printable(_ text: String) -> String {
        var shown = ""
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format {
                shown += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }
}
