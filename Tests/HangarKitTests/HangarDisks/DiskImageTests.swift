import Foundation
import HangarSupport
import Testing

@testable import HangarDisks

struct DiskImageTests {
    @Test func eachAttachedImageIsListedByItsWholeDisk() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>images</key><array><dict>
                <key>image-path</key><string>/Users/me/install.img</string>
                <key>system-entities</key><array>
                    <dict><key>dev-entry</key><string>/dev/disk5s1</string></dict>
                    <dict><key>dev-entry</key><string>/dev/disk5</string></dict>
                </array>
            </dict></array>
            </dict></plist>
            """

        let images = try DiskImage.attachedImages(in: Data(plist.utf8))

        #expect(images.map(\.path) == ["/Users/me/install.img"])
        #expect(images.map(\.device) == ["/dev/disk5"])
    }

    /// An image with APFS also lists the containers macOS made of it, as disks with names as short as the whole
    /// disk's; the shortest name used to pick one of those.
    @Test func theWholeDiskIsTheOneWithThePartitionSchemeNotAnAPFSContainer() throws {
        let entity = { (device: String, hint: String) in
            "<dict><key>dev-entry</key><string>\(device)</string><key>content-hint</key><string>\(hint)</string></dict>"
        }
        let container = "EF57347C-0000-11AA-AA11-00306543ECAC"
        let entities = [
            entity("/dev/disk4s1", "EFI"), entity("/dev/disk6", container), entity("/dev/disk4s3", "Apple_APFS"),
            entity("/dev/disk5", container), entity("/dev/disk4", "GUID_partition_scheme"),
        ]
        let plist = """
            <plist version="1.0"><dict><key>images</key><array><dict>
                <key>image-path</key><string>/Users/me/mac/disk.img</string>
                <key>system-entities</key><array>\(entities.joined())</array>
            </dict></array></dict></plist>
            """

        let images = try DiskImage.attachedImages(in: Data(plist.utf8))

        #expect(images.map(\.device) == ["/dev/disk4"])
    }

    /// An unreadable list used to count as "nothing attached", so an attach of an image someone else had open
    /// believed it owned the image and force-detached it from them.
    @Test func anUnreadableImageListIsAnErrorNotAnEmptyList() {
        #expect(throws: (any Error).self) { try DiskImage.attachedImages(in: Data("not a plist".utf8)) }
        #expect(throws: HangarError.self) { try DiskImage.attachedImages(in: Data("<plist><array/></plist>".utf8)) }
    }
}
