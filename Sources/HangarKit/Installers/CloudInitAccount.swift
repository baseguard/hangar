import CryptoKit
import Foundation
import HangarSupport

package struct CloudInitAccount: Sendable {
    package var username: String
    package var password: String
    package var sshKey: String?

    package init(username: String, password: String, sshKey: String? = nil) {
        self.username = username
        self.password = password
        self.sshKey = sshKey
    }

    package func validate() throws {
        guard username.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) != nil, username != "root" else {
            throw HangarError(
                "Linux user names have up to 32 lowercase letters, digits, '_' or '-', and can't be root.")
        }
        guard !password.isEmpty else { throw HangarError("Enter a password for the account.") }
        let keyPattern =
            /(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9-]+@openssh\.com) [A-Za-z0-9+\/=]+( [^\s"\\]+)?/
        if let sshKey, sshKey.wholeMatch(of: keyPattern) == nil {
            throw HangarError("The SSH key must be one public key line, like the contents of ~/.ssh/id_ed25519.pub.")
        }
    }
}
