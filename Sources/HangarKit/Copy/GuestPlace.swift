import Foundation

/// A folder the Files window's sidebar offers, like Finder's Favorites and Locations.
package struct GuestPlace: Equatable, Identifiable, Sendable {
    package enum Kind: Sendable {
        case home
        /// HangarDrop, where files dropped on the VM's window land.
        case drop
        case disk
    }

    package let kind: Kind
    package let name: String
    /// In the guest's own form, like /home/dev or C:\Users\dev.
    package let path: String

    package var id: String { path }

    /// The home folder, and HangarDrop when the home has it, from one listing of the home.
    package static func favorites(in home: GuestFolder, os: GuestOS) -> [GuestPlace] {
        let homePlace = GuestPlace(
            kind: .home, name: GuestFileBrowser.folderName(of: home.path, os: os), path: home.path)
        let hasDrop = home.entries.contains { $0.kind == .folder && $0.name == GuestPlace.dropFolder }
        guard hasDrop else { return [homePlace] }

        let dropPath = GuestFileBrowser.path(of: GuestPlace.dropFolder, in: home.path, os: os)
        return [homePlace, GuestPlace(kind: .drop, name: GuestPlace.dropFolder, path: dropPath)]
    }

    private static let dropFolder = "HangarDrop"

    /// The top of the VM's disk: / on Linux and macOS, named after the VM like Finder's Macintosh HD. On Windows only
    /// C:, the drive the agent's `ls` can name without a way to list drives.
    package static func disks(of vm: String, os: GuestOS) -> [GuestPlace] {
        switch os {
        case .linux, .macOS:
            [GuestPlace(kind: .disk, name: vm, path: "/")]
        case .windows:
            [GuestPlace(kind: .disk, name: "C:", path: #"C:\"#)]
        }
    }
}
