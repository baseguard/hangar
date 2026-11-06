import Foundation
import Testing

@testable import HangarKit

struct RemoteDesktopTests {
    @Test func remoteDesktopFileUsesCRLFAndTheVMsUser() {
        let contents = RemoteDesktop.fileContents(user: "admin", address: "10.88.0.12")

        #expect(contents.hasSuffix("\r\n"))
        let lines = contents.components(separatedBy: "\r\n")
        #expect(lines.first == "full address:s:10.88.0.12")
        #expect(lines.contains("username:s:admin"))
        #expect(lines.contains("audiomode:i:0"))
        #expect(lines.contains("audiocapturemode:i:1"))
    }
}
