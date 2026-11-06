import CryptoKit
import Foundation

enum Digests {
    static let prefix = "sha256:"

    static func isValid(_ digest: String) -> Bool {
        digest.hasPrefix(prefix) && hex(of: digest).wholeMatch(of: /[0-9a-f]{64}/) != nil
    }

    static func hex(of digest: String) -> Substring {
        digest.dropFirst(prefix.count)
    }
}

extension Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256.Digest {
    var ociDigest: String { Digests.prefix + hex }
}
