import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Share: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Share folders on this Mac with a VM.",
        discussion: """
            Examples:
              hangar share add deb ~/src
                  Share ~/src with deb as src.
              hangar share add deb ~/datasets --name data --read-only
                  Share ~/datasets as data, without letting the VM change it.
              hangar share remove deb data
                  Stop sharing it.

            Shares appear in /Volumes/My Shared Files on macOS, on drive Z: on Windows and in /mnt/hangar on Linux. A \
            running VM gets the change at once when it can.
            """,
        subcommands: [Add.self, Remove.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Share a folder with a VM.")

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The folder on this Mac.", valueName: "folder")) var path: String
        @Option(help: "The name the VM sees (default: the folder's name).") var name: String?
        @Flag(help: "Don't let the VM change the folder.") var readOnly = false

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            let folder = try SharedFolder.make(path: path, name: name, readOnly: readOnly)
            try bundle.updateConfig { config in
                config.sharedFolders.removeAll { $0.name == folder.name }
                config.sharedFolders.append(folder)
            }
            print("Sharing \(folder.path) as '\(folder.name)'\(try appliedNow(bundle)).")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop sharing a folder with a VM.", aliases: ["rm"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The share's name.", valueName: "name")) var name: String

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            try bundle.updateConfig { config in
                guard config.sharedFolders.contains(where: { $0.name == name }) else {
                    throw HangarError("'\(vm)' has no share named '\(name)'.")
                }
                config.sharedFolders.removeAll { $0.name == name }
            }
            print("Removed share '\(name)'\(try appliedNow(bundle)).")
        }
    }
}

private func appliedNow(_ bundle: VMBundle) throws -> String {
    try VMSettings.applySharedFoldersLive(to: bundle) ? " (applied now)" : ""
}
