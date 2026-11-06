import Foundation
import HangarSupport

package struct MacProvisioning: Codable, Hashable, Sendable {
    package var fullName: String
    package var username: String
    package var password = ""
    package var autoLogin: Bool
    package var remoteLogin: Bool
    package var passwordItem = UUID().uuidString

    enum CodingKeys: String, CodingKey {
        case fullName, username, autoLogin, remoteLogin, passwordItem
    }

    package init(fullName: String, username: String, password: String, autoLogin: Bool = true, remoteLogin: Bool = true)
    {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.autoLogin = autoLogin
        self.remoteLogin = remoteLogin
    }

    /// Where VZMacOSInstaller's provisioning options came in.
    static let firstSupportedMajorVersion = 27

    static func checkSupported(majorVersion: Int) throws {
        guard majorVersion >= firstSupportedMajorVersion else {
            throw HangarError("Automatic account setup needs a macOS \(firstSupportedMajorVersion) or newer guest.")
        }
    }

    func savePassword() throws {
        try Keychain.save(password, for: passwordItem, label: "Hangar VM account password")
    }

    func loadPassword() throws -> String {
        do {
            return try Keychain.read(passwordItem)
        } catch is Keychain.Missing {
            throw HangarError(
                "The password for “\(username)” is no longer in your Keychain, so the account can't be set up. Delete this VM and create it again."
            )
        }
    }

    /// For a VM that is deleted or no longer needs the password; a Keychain that refuses only keeps the item.
    func forgetPassword() {
        do {
            try Keychain.delete(passwordItem)
        } catch {
            HangarLog.warning("The password of “\(username)” stays in your Keychain: \(error)")
        }
    }

    package func validate() throws {
        guard username.wholeMatch(of: /[a-z_][a-z0-9_-]{0,31}/) != nil else {
            throw HangarError("macOS user names have up to 32 lowercase letters, digits, '_' or '-'.")
        }
        guard !password.isEmpty else { throw HangarError("Enter a password for the account.") }
    }
}
