import Foundation
import HangarSupport
import Testing

@testable import HangarKit

struct GuestDropTests {
    @Test func theGuestsReasonIsShownWithoutControlCharactersAndNobodySignedInSaysWhatToDo() {
        let reason = GuestDrop.guestReason(Data("disk full\u{1B}[2J\n".utf8), vm: "deb")
        let nobody =
            GuestDrop.signInSentence(
                for: HangarError("Nobody is signed in at the guest's screen."), vm: "deb") as? HangarError

        #expect(reason?.message == "disk full?[2J")
        #expect(GuestDrop.guestReason(Data(), vm: "deb") == nil)
        #expect(nobody?.message == "Sign in to 'deb' first, then drop the files again.")
    }

    @Test func onlyFilesOnThisMacCanBeDropped() throws {
        let file = URL(fileURLWithPath: "/Users/someone/report.pdf")
        let web = try #require(URL(string: "https://example.com/report.pdf"))
        let data = try #require(URL(string: "data:text/plain,hello"))
        let custom = try #require(URL(string: "hangar://drop?file=/etc/passwd"))

        let files = GuestDrop.localFiles([web, file, data, custom])

        #expect(files == [file])
    }

    @Test func droppedItemsWithOneNameEachGetTheirOwn() {
        var names: Set<String> = []

        let picked = ["r.pdf", "r.pdf", "R.pdf", "notes"].map { GuestDrop.unusedName($0, in: &names) }

        #expect(picked == ["r.pdf", "r 2.pdf", "R 3.pdf", "notes"])
    }

    @Test func onlyToolsIsReservedForHangarsOwnShare() throws {
        let folder = FileManager.default.temporaryDirectory

        #expect(SharedFolder.isReserved("TOOLS"))
        #expect(!SharedFolder.isReserved("Drop"))
        #expect(throws: (any Error).self) { try SharedFolder.make(path: folder.path, name: "tools", readOnly: true) }
    }
}
