import Foundation
import HangarSupport
import Testing

@testable import HangarSecrets

struct SecretAuthorityTests {
    /// A damaged record used to count as "no authority", so a new root was made and the guest kept trusting the old
    /// one.
    @Test func aDamagedAuthorityRecordIsAnErrorNotANewAuthority() {
        let failure = #expect(throws: HangarError.self) { try SecretAuthority.stored(from: "{\"rootKey\": 1}") }

        let problem = "Hangar's certificate authority for this VM in your Keychain can't be read"
        #expect(failure?.message.hasPrefix(problem) == true)
    }
}
