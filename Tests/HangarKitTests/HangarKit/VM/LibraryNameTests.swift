import Foundation
import HangarKit
import HangarSupport
import Testing

@Suite(.temporaryHangarHome)
struct LibraryNameTests {
    @Test func namesAreUniqueIgnoringCaseAndVMsBeingCreated() async throws {
        try HangarPaths.createDirectory(HangarPaths.vms)
        try FileManager.default.createDirectory(
            at: HangarPaths.vms.appendingPathComponent("Debian"), withIntermediateDirectories: false)
        let staging = HangarPaths.vms.appendingPathComponent(".creating-ubuntu-1A2B3C4D")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        #expect(VMLibrary.exists("debian"))
        #expect(VMLibrary.exists("UBUNTU"))
        #expect(!VMLibrary.exists("ubuntu", ignoring: staging))
        #expect(!VMLibrary.exists("ubuntu-2"))
        #expect(!VMLibrary.exists("deb"))
        #expect(throws: (any Error).self) { try VMLibrary.validate(name: "DEBIAN") }
        for bad in ["my vm", "vm_1", "-vm", "vm-", "vm.local", ""] {
            #expect(!VMLibrary.isValidName(bad))
        }
        #expect(VMLibrary.isValidName("deb-13"))
    }

    @Test(arguments: ["..", "../..", "../x", ".hidden", "a/b", ""])
    func vmLookupRejectsPathTraversal(_ name: String) {
        #expect(throws: (any Error).self) { try VMLibrary.bundle(named: name) }
    }
}
