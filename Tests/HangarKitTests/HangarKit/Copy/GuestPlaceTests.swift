import Foundation
import Testing

@testable import HangarKit

struct GuestPlaceTests {
    private func home(_ path: String, folders: [String], files: [String] = []) throws -> GuestFolder {
        let folderEntries = folders.map { #"{"name":"\#($0)","kind":"folder","link":false,"size":0,"modified":0}"# }
        let fileEntries = files.map { #"{"name":"\#($0)","kind":"file","link":false,"size":0,"modified":0}"# }
        let entries = (folderEntries + fileEntries).joined(separator: ",")
        let escapedPath = path.replacingOccurrences(of: #"\"#, with: #"\\"#)
        let json = #"{"path":"\#(escapedPath)","parent":null,"truncated":false,"entries":[\#(entries)]}"#
        return try GuestFileBrowser.folder(from: Data(json.utf8), vm: "deb")
    }

    @Test func favoritesAreTheHomeAndItsHangarDrop() throws {
        let listed = try home("/home/admin", folders: ["Downloads", "HangarDrop"], files: ["Desktop"])

        let favorites = GuestPlace.favorites(in: listed, os: .linux)

        #expect(favorites.map(\.name) == ["admin", "HangarDrop"])
        #expect(favorites.map(\.kind) == [.home, .drop])
        #expect(favorites.map(\.path) == ["/home/admin", "/home/admin/HangarDrop"])
    }

    @Test func aHomeWithoutHangarDropIsTheOnlyFavorite() throws {
        let listed = try home(#"C:\Users\dev"#, folders: ["Desktop"], files: ["HangarDrop"])

        let favorites = GuestPlace.favorites(in: listed, os: .windows)

        #expect(favorites.map(\.path) == [#"C:\Users\dev"#])
    }

    @Test func theDiskIsTheRootOrDriveC() {
        #expect(GuestPlace.disks(of: "deb", os: .linux).map(\.path) == ["/"])
        #expect(GuestPlace.disks(of: "deb", os: .linux).map(\.name) == ["deb"])
        #expect(GuestPlace.disks(of: "win", os: .windows).map(\.path) == [#"C:\"#])
    }
}
