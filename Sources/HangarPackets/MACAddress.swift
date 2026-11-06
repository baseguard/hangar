import Foundation

package enum MACAddress {
    package static let length = 6

    /// `string` written the one way Hangar keeps addresses: six lowercase hex octets; nil for anything else.
    package static func normalize(_ string: String) -> String? {
        bytes(string).map(Self.string)
    }

    package static func bytes(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == length else { return nil }

        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part, radix: 16) else { return nil }
            octets.append(value)
        }
        return octets
    }

    package static func string(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
