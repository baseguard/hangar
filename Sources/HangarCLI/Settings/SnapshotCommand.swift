import ArgumentParser
import Foundation
import HangarKit

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Save a VM's disk and go back to it later.",
        discussion: """
            Examples:
              hangar snapshot take deb clean
                  Save deb as it is now, as clean.
              hangar snapshot list deb
              hangar snapshot restore deb clean
                  Put the stopped VM deb back to clean.
              hangar snapshot rename deb clean base
              hangar snapshot delete deb clean

            Snapshots are instant and only take space as the VM changes. A snapshot keeps the disk, not the memory: \
            a VM restored to it starts up fresh.
            """,
        subcommands: [Take.self, List.self, Restore.self, Rename.self, Delete.self]
    )

    struct Take: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a VM's disk as a snapshot.", aliases: ["create"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The snapshot's name (default: the date and time).", valueName: "snapshot"))
        var name: String?

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            let snapshotName = name ?? Snapshots.defaultName()
            runMain { [vm] in
                let snapshot = try await Snapshots.take(of: bundle, name: snapshotName)
                print("Took snapshot '\(snapshot.name)' of '\(vm)'.")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a VM's snapshots.", aliases: ["ls"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String

        func run() throws {
            let snapshots = try VMLibrary.bundle(named: vm).snapshots
            guard !snapshots.isEmpty else {
                print("'\(vm)' has no snapshots. Take one with `hangar snapshot take \(vm)`.")
                return
            }

            let rows = snapshots.map { [$0.name, $0.createdAt.formatted(date: .abbreviated, time: .shortened)] }
            printTable([["NAME", "TAKEN"]] + rows)
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put a stopped VM back to a snapshot.",
            discussion: "Everything since the snapshot is lost, unless you take another snapshot first."
        )

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The snapshot.", valueName: "snapshot")) var name: String

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            try Snapshots.restore(try bundle.snapshot(named: name), to: bundle)
            print("Restored '\(vm)' to '\(name)'.")
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a VM's snapshot.")

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The snapshot.", valueName: "snapshot")) var name: String
        @Argument(help: ArgumentHelp("Its new name.", valueName: "new-name")) var newName: String

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            try Snapshots.rename(try bundle.snapshot(named: name), of: bundle, to: newName)
            print("Renamed snapshot '\(name)' to '\(newName)'.")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a VM's snapshots.", aliases: ["rm"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The snapshots.", valueName: "snapshot")) var names: [String]

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            for name in names {
                try Snapshots.delete(try bundle.snapshot(named: name))
                print("Deleted snapshot '\(name)'.")
            }
        }
    }
}
