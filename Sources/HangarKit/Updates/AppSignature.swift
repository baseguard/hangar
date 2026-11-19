import Foundation
import HangarSupport
import Security

/// Whether a download is Hangar as Baseguard released it: signed with Baseguard's Developer ID, notarized by Apple,
/// and unchanged since. A disk image and its digest both come from GitHub; this is what makes them trustworthy.
enum AppSignature {
    private static let publisher =
        #"anchor apple generic and certificate leaf[subject.OU] = "D8Y7HXTBTG" and notarized"#
    private static let app = publisher + #" and identifier "io.baseguard.hangar""#

    /// Before the image is attached: attaching has macOS read the file systems in it, so only an image Baseguard
    /// signed gets that far. The signature covers every byte of the image.
    static func checkDiskImage(_ diskImage: URL) throws {
        try check(diskImage, against: publisher, flags: kSecCSStrictValidate, called: "The downloaded disk image")
    }

    /// The app copied out of the image, nested code included: the command line, the Share extension and the guest
    /// agents.
    static func checkApp(_ app: URL) throws {
        let flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
        try check(app, against: Self.app, flags: flags, called: "The downloaded Hangar")
    }

    private static func check(_ file: URL, against requirement: String, flags: UInt32, called name: String) throws {
        let code = try staticCode(of: file)
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), try compiled(requirement))
        guard status == errSecSuccess else {
            throw HangarError(
                "\(name) isn't signed by Baseguard and notarized by Apple (\(message(status))), so Hangar didn't install it."
            )
        }
    }

    private static func staticCode(of file: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(file as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw HangarError("Could not read the signature of \(file.path): \(message(status)).")
        }
        return code
    }

    private static func compiled(_ requirement: String) throws -> SecRequirement {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw HangarError("Hangar's signing requirement doesn't compile: \(message(status)).")
        }
        return compiled
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
