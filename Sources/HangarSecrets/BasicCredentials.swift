import Foundation

/// HTTP Basic authentication (RFC 7617): an Authorization value `Basic <base64 of user:password>`. git sends a token
/// this way, as the password its credential helper gave, so a placeholder there is hidden in base64.
enum BasicCredentials {
    private static let scheme = "basic"

    /// The `user:password` of a Basic Authorization value; `nil` for another scheme or a value that isn't base64 of
    /// UTF-8 text.
    static func decoded(_ fieldValue: String) -> String? {
        let parts = fieldValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == scheme else { return nil }
        let encoded = parts[1].trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fieldValue(credentials: String) -> String {
        "Basic " + Data(credentials.utf8).base64EncodedString()
    }

    static func fieldValue(user: String, password: String) -> String {
        fieldValue(credentials: "\(user):\(password)")
    }
}
