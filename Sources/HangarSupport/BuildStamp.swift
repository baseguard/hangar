import Foundation
import Security

package struct BuildStamp: Codable, Equatable, Sendable {
    package var signer: String

    /// Who signed the running Hangar: its team, or the hash of an ad hoc signature.
    package static var current: BuildStamp? {
        guard let details = signingInformation(of: HangarExecutable.url) else { return nil }

        if let team = details[kSecCodeInfoTeamIdentifier as String] as? String {
            return BuildStamp(signer: "team \(team)")
        }
        if let unique = details[kSecCodeInfoUnique as String] as? Data {
            return BuildStamp(signer: "ad hoc " + unique.map { String(format: "%02x", $0) }.joined())
        }
        return BuildStamp(signer: "unsigned")
    }

    private static func signingInformation(of executable: URL) -> [String: Any]? {
        var code: SecStaticCode?
        let made = SecStaticCodeCreateWithPath(executable.resolvingSymlinksInPath() as CFURL, [], &code)
        guard made == errSecSuccess, let code else { return nil }

        var information: CFDictionary?
        let copied = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard copied == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}
