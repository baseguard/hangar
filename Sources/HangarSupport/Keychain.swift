import Foundation
import Security

package enum Keychain {
    package static let service = "io.baseguard.hangar"

    /// The app and the `hangar` command share their items through this access group, so neither is asked for access to
    /// what the other saved. An ad hoc build, which can't have the entitlement, uses the login keychain instead.
    private static let sharedGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        return (groups as? [String])?.first
    }()

    /// Every query starts here: Hangar's service, in the shared group when there is one.
    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let sharedGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = sharedGroup
        }
        return query
    }

    package static func save(_ secret: String, for account: String, label: String, comment: String? = nil) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        // VMs that start on their own at login need their secrets before the Mac is unlocked again. The VMs live on
        // this Mac, so their secrets stay on it too, never restored from a backup onto another one.
        var values: [String: Any] = [
            kSecAttrLabel as String: label, kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        values[kSecAttrComment as String] = comment
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HangarError("Could not save \(label) in your Keychain: \(message(status)).")
        }
    }

    package static func accounts(startingWith prefix: String) throws -> [(account: String, comment: String?)] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw HangarError("Could not read Hangar's items from your Keychain: \(message(status)).")
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else {
                return nil
            }
            return (account, item[kSecAttrComment as String] as? String)
        }
    }

    package static func read(_ account: String) throws -> String {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecItemNotFound
                ? Missing() : HangarError("Could not read Hangar's item from your Keychain: \(message(status)).")
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// False for an item that wasn't there; anything else that keeps the item is an error.
    @discardableResult
    package static func delete(_ account: String) throws -> Bool {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw HangarError("Could not delete Hangar's item from your Keychain: \(message(status)).")
        }
    }

    package struct Missing: Error {}

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
