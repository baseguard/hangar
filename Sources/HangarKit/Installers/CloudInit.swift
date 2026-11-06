import CryptoKit
import Foundation
import HangarDisks
import HangarSupport

package enum CloudInit {
    package static func validate(userData: String) throws {
        guard userData.hasPrefix("#cloud-config") || userData.hasPrefix("#!") else {
            throw HangarError("Cloud-init user data must start with #cloud-config or a #! script line.")
        }
        guard userData.utf8.count <= 1 << 20 else { throw HangarError("Cloud-init user data can be at most 1 MB.") }
    }

    static func userData(account: CloudInitAccount?, custom: String?) -> String? {
        let generated = account.map { userData(for: $0, passwordHash: sha512Crypt($0.password, salt: randomSalt())) }
        guard generated != nil || custom != nil else { return nil }
        let group = account.map(groupPart)
        return multipart([generated, custom, group, agentInstall].compactMap { $0 })
    }

    /// A part after the user's own user data adds to what that set instead of replacing it.
    private static let appendingMerge = #"merge_how: "dict(recurse_list,no_replace)+list(append)+str()""#

    /// Ubuntu has a system group named admin and useradd won't make a user group that exists: this part makes the
    /// account's group only when missing, after custom user data, and appends to the groups that sets.
    static func groupPart(for account: CloudInitAccount) -> String {
        """
        #cloud-config
        \(appendingMerge)
        groups:
          - \(quoted(account.username))

        """
    }

    static let agentInstall = """
        #cloud-config
        \(appendingMerge)
        runcmd:
          - [mkdir, -p, \(GuestTools.linuxMountPoint)]
          - [mount, -t, virtiofs, -o, "nosuid,nodev", \(ConfigurationBuilder.linuxShareTag), \(GuestTools.linuxMountPoint)]
          - [\(GuestTools.linuxMountPoint)/\(GuestTools.shareName)/\(GuestTools.linuxAgent), install]

        """

    static func multipart(_ parts: [String]) -> String {
        var boundary = "==HANGAR-\(UUID().uuidString)=="
        while parts.contains(where: { $0.contains(boundary) }) {
            boundary = "==HANGAR-\(UUID().uuidString)=="
        }

        var text = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\nMIME-Version: 1.0\n\n"
        for part in parts {
            let type = part.hasPrefix("#!") ? "text/x-shellscript" : "text/cloud-config"
            text +=
                "--\(boundary)\nContent-Type: \(type); charset=\"utf-8\"\nContent-Transfer-Encoding: 8bit\n\n"
                + part + (part.hasSuffix("\n") ? "" : "\n")
        }
        return text + "--\(boundary)--\n"
    }

    static func userData(for account: CloudInitAccount, passwordHash: String) -> String {
        var lines = [
            "#cloud-config",
            "ssh_pwauth: true",
            "chpasswd:",
            "  expire: false",
            "users:",
            "  - name: \(quoted(account.username))",
            "    primary_group: \(quoted(account.username))",
            "    lock_passwd: false",
            "    passwd: \(quoted(passwordHash))",
            "    shell: \"/bin/bash\"",
            "    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]",
        ]

        if let sshKey = account.sshKey {
            lines += ["    ssh_authorized_keys:", "      - \(quoted(sshKey))"]
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func metaData(hostname: String) -> String {
        let name = hostname.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "instance-id: \(quoted(UUID().uuidString.lowercased()))\nlocal-hostname: \(quoted(String(name)))\n"
    }

    static let networkConfig = """
        version: 2
        ethernets:
          primary:
            match:
              name: "e*"
            dhcp4: true

        """

    static func writeSeed(account: CloudInitAccount?, userData custom: String?, hostname: String, to url: URL) throws {
        guard let text = userData(account: account, custom: custom) else { return }
        try write(userData: Data(text.utf8), hostname: hostname, to: url)
    }

    static func writeSeedForCopiedDisk(
        account: CloudInitAccount?, userData custom: String?, hostname: String, to url: URL
    ) throws {
        let text = userData(account: account, custom: custom) ?? multipart([agentInstall])
        try write(userData: Data(text.utf8), hostname: hostname, to: url)
    }

    static func copySeed(from source: URL, to url: URL, hostname: String) throws {
        let files: [String: Data]
        do {
            files = try ISOImage.files(in: Data(contentsOf: source))
        } catch {
            throw HangarError("Could not read the cloud-init disk \(source.path): \(error.localizedDescription)")
        }
        guard let userData = files["user-data"] else {
            throw HangarError("\(source.path) has no cloud-init user-data.")
        }
        try write(userData: userData, hostname: hostname, to: url)
    }

    private static func write(userData: Data, hostname: String, to url: URL) throws {
        let image = try ISOImage.make(
            files: [
                ("user-data", userData),
                ("meta-data", Data(metaData(hostname: hostname).utf8)),
                ("network-config", Data(networkConfig.utf8)),
            ], volume: "cidata")
        guard FileManager.default.createFile(atPath: url.path, contents: image, attributes: [.posixPermissions: 0o600])
        else {
            throw HangarError("Could not write the cloud-init settings to \(url.path).")
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// sha512-crypt as glibc does it (the "$6$" scheme): a 16-character salt, 5000 rounds over SHA-512's 64-byte
    /// digest, written out in 86 characters of its own base64.
    private static let saltLength = 16
    private static let rounds = 5000
    private static let digestLength = 64
    private static let digestGroups = 21

    private static func randomSalt() -> String {
        String((0..<saltLength).map { _ in alphabet[Int.random(in: alphabet.indices)] })
    }

    static func sha512Crypt(_ password: String, salt: String) -> String {
        let key = Array(password.utf8)
        let saltBytes = Array(salt.utf8.prefix(saltLength))

        let initial = initialDigest(key: key, salt: saltBytes)
        let digest = stretched(initial, key: key, salt: saltBytes)
        return "$6$\(String(decoding: saltBytes, as: UTF8.self))$\(encoded(digest))"
    }

    private static func initialDigest(key: [UInt8], salt: [UInt8]) -> [UInt8] {
        let alternate = Array(SHA512.hash(data: key + salt + key))

        var context = key + salt
        var remaining = key.count
        while remaining > digestLength {
            context += alternate
            remaining -= digestLength
        }
        context += alternate.prefix(remaining)

        var bits = key.count
        while bits > 0 {
            context += bits & 1 == 1 ? alternate : key
            bits >>= 1
        }
        return Array(SHA512.hash(data: context))
    }

    private static func stretched(_ initial: [UInt8], key: [UInt8], salt: [UInt8]) -> [UInt8] {
        let keyDigest = Array(SHA512.hash(data: Array(repeating: key, count: key.count).flatMap { $0 }))
        let keySequence = repeated(keyDigest, to: key.count)
        let saltRepeats = saltLength + Int(initial[0])
        let saltDigest = Array(SHA512.hash(data: Array(repeating: salt, count: saltRepeats).flatMap { $0 }))
        let saltSequence = repeated(saltDigest, to: salt.count)

        var digest = initial
        for round in 0..<rounds {
            var block: [UInt8] = round % 2 == 1 ? keySequence : digest
            if round % 3 != 0 { block += saltSequence }
            if round % 7 != 0 { block += keySequence }
            block += round % 2 == 1 ? digest : keySequence
            digest = Array(SHA512.hash(data: block))
        }
        return digest
    }

    private static func encoded(_ digest: [UInt8]) -> String {
        var text = ""
        for group in 0..<digestGroups {
            let indices = [group, group + digestGroups, group + 2 * digestGroups]
            let rotated = Array(indices[(group % 3)...] + indices[..<(group % 3)])
            text += encode(digest[rotated[0]], digest[rotated[1]], digest[rotated[2]], characters: 4)
        }
        return text + encode(0, 0, digest[digestLength - 1], characters: 2)
    }

    private static func repeated(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        (0..<count).map { bytes[$0 % bytes.count] }
    }

    private static func encode(_ high: UInt8, _ middle: UInt8, _ low: UInt8, characters: Int) -> String {
        var word = UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
        var result = ""
        for _ in 0..<characters {
            result.append(alphabet[Int(word & 0x3f)])
            word >>= 6
        }
        return result
    }
}
