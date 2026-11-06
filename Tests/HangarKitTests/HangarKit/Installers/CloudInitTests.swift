import Foundation
import HangarSupport
import Testing

@testable import HangarDisks
@testable import HangarKit

@Suite(.temporaryHangarHome)
struct CloudInitTests {
    @Test func passwordsAreHashedLikeLinux() {
        #expect(
            CloudInit.sha512Crypt("Hello world!", salt: "saltstring")
                == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"
        )
        #expect(
            CloudInit.sha512Crypt("test", salt: "abcdefgh")
                == "$6$abcdefgh$3rj1vTLX64btReFsM4MQ22otcD40l7vbtw7qCyr0dxc4kxNmgx53xVM8gWiLYbCqTHTbXFaVFU7ZT28pnvdyu0")
        let long = "a long password that is well over sixty-four bytes, so the block branch runs: 0123456789"
        #expect(
            CloudInit.sha512Crypt(long, salt: "saltstring16char")
                == "$6$saltstring16char$ZqC/8jf0WAt5GXkjP4/kyB2DcFrY/q/Dq7sbnGTvTTm9PzRNobSBpw7GOpaAevCX.MNQn807kkzIc.UzzExYN1"
        )
    }

    @Test func accountsAreChecked() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq4 me@mac"

        #expect(throws: Never.self) {
            try CloudInitAccount(username: "dev", password: "secret", sshKey: key).validate()
        }
        #expect(throws: (any Error).self) { try CloudInitAccount(username: "root", password: "secret").validate() }
        #expect(throws: (any Error).self) { try CloudInitAccount(username: "Dev", password: "secret").validate() }
        #expect(throws: (any Error).self) { try CloudInitAccount(username: "dev", password: "").validate() }
        #expect(throws: (any Error).self) {
            try CloudInitAccount(username: "dev", password: "x", sshKey: key + "\nruncmd: [x]").validate()
        }
        #expect(throws: (any Error).self) {
            try CloudInitAccount(username: "dev", password: "x", sshKey: "ssh-ed25519 AAAA a\"b").validate()
        }
    }

    @Test func theAccountGroupIsMadeAfterCustomUserData() throws {
        let account = CloudInitAccount(username: "admin", password: "s3cret-pass")

        let userData = try #require(CloudInit.userData(account: account, custom: "#cloud-config\ngroups: [docker]\n"))

        let custom = try #require(userData.range(of: "groups: [docker]"))
        let group = try #require(userData.range(of: "groups:\n  - \"admin\""))
        #expect(custom.upperBound <= group.lowerBound)
        #expect(userData.contains("primary_group: \"admin\""))
    }

    @Test func theSeedHoldsOnlyTheHash() throws {
        let account = CloudInitAccount(
            username: "dev", password: "s3cret-pass", sshKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq4 me@mac")

        let userData = CloudInit.userData(
            for: account, passwordHash: CloudInit.sha512Crypt(account.password, salt: "abcdefgh"))

        #expect(userData.hasPrefix("#cloud-config\n"))
        #expect(userData.contains("passwd: \"$6$abcdefgh$"))
        #expect(userData.contains("lock_passwd: false"))
        #expect(userData.contains("primary_group: \"dev\""))
        #expect(userData.contains("- \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq4 me@mac\""))
        #expect(!userData.contains("s3cret-pass"))
        #expect(CloudInit.metaData(hostname: "My_VM").contains("local-hostname: \"my-vm\""))

        let seed = HangarPaths.home.appendingPathComponent("cidata.iso")
        try CloudInit.writeSeed(account: account, userData: nil, hostname: "dev", to: seed)

        let attributes = try FileManager.default.attributesOfItem(atPath: seed.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let handle = try FileHandle(forReadingFrom: seed)
        defer { try? handle.close() }
        try handle.seek(toOffset: 16 * 2048 + 40)
        #expect(try handle.read(upToCount: 6) == Data("CIDATA".utf8))
        let contents = try Data(contentsOf: seed)
        #expect(contents.range(of: Data("s3cret-pass".utf8)) == nil)
        let seeded = try #require(try isoFiles(contents)["USER-DATA;1"].map { String(decoding: $0, as: UTF8.self) })
        #expect(seeded.contains("Content-Type: text/cloud-config"))
        #expect(!seeded.contains("Content-Type: text/x-shellscript"))
        #expect(seeded.contains("  - [/mnt/hangar/Tools/hangar-agent, install]\n"))
        #expect(
            try isoFiles(contents)["META-DATA;1"].map { String(decoding: $0, as: UTF8.self) }?.contains(
                "local-hostname: \"dev\"") == true)
    }

    @Test func customUserDataIsAddedAsItsOwnPart() throws {
        let account = CloudInitAccount(username: "dev", password: "s3cret-pass")
        let custom = "#cloud-config\npackages: [git]\n"

        let both = try #require(CloudInit.userData(account: account, custom: custom))
        #expect(both.hasPrefix("Content-Type: multipart/mixed; boundary=\"==HANGAR-"))
        #expect(both.components(separatedBy: "Content-Type: text/cloud-config").count == 5)
        #expect(both.contains(custom))
        #expect(both.contains("passwd: \"$6$"))
        #expect(!both.contains("s3cret-pass"))

        let script = try #require(CloudInit.userData(account: account, custom: "#!/bin/sh\necho hi"))
        #expect(script.contains("Content-Type: text/x-shellscript"))

        let customOnly = try #require(CloudInit.userData(account: nil, custom: custom))
        #expect(customOnly.contains(custom))
        #expect(customOnly.components(separatedBy: "Content-Type: text/cloud-config").count == 3)
        #expect(!customOnly.contains("Content-Type: text/x-shellscript"))

        #expect(CloudInit.userData(account: nil, custom: nil) == nil)
        #expect(throws: (any Error).self) { try CloudInit.validate(userData: "packages: [git]") }
        #expect(throws: Never.self) { try CloudInit.validate(userData: custom) }
    }

    @Test func hangarsPartComesLastAndAddsToTheUsersCommands() throws {
        let custom = "#cloud-config\nruncmd:\n  - [touch, /tmp/custom]\n"
        let text = try #require(CloudInit.userData(account: nil, custom: custom))
        let boundary = try #require(text.firstMatch(of: /boundary="([^"]+)"/)).1

        #expect(text.hasSuffix(CloudInit.agentInstall + "--\(boundary)--\n"))
        let customEnd = try #require(text.range(of: custom)).upperBound
        let agentStart = try #require(text.range(of: CloudInit.agentInstall)).lowerBound
        #expect(customEnd < agentStart)
        #expect(CloudInit.agentInstall.contains(#"merge_how: "dict(recurse_list,no_replace)+list(append)+str()""#))
        let commands = CloudInit.agentInstall.split(separator: "\n").filter { $0.hasPrefix("  - ") }
        #expect(
            commands == [
                "  - [mkdir, -p, /mnt/hangar]",
                "  - [mount, -t, virtiofs, -o, \"nosuid,nodev\", hangar, /mnt/hangar]",
                "  - [/mnt/hangar/Tools/hangar-agent, install]",
            ])
    }

    @Test func userTextThatLooksLikeMIMEKeepsItsPlace() throws {
        let tricky =
            "#cloud-config\nwrite_files:\n  - content: |\n      --==HANGAR-fake==\n      Content-Type: text/x-shellscript\n      --==HANGAR-fake==--\n    path: /tmp/x\n"

        let text = try #require(
            CloudInit.userData(account: CloudInitAccount(username: "dev", password: "x"), custom: tricky))
        let boundary = try #require(text.firstMatch(of: /boundary="([^"]+)"/)).1

        #expect(!tricky.contains(boundary))
        #expect(text.components(separatedBy: "--\(boundary)\n").count == 5)
        #expect(text.hasSuffix("--\(boundary)--\n"))
        #expect(text.components(separatedBy: "Content-Transfer-Encoding: 8bit").count == 5)
        #expect(text.contains(tricky))
    }

    @Test func clonesGetTheirOwnInstanceAndName() throws {
        let account = CloudInitAccount(username: "dev", password: "s3cret-pass")
        let source = HangarPaths.home.appendingPathComponent("source.iso")
        let copy = HangarPaths.home.appendingPathComponent("copy.iso")
        try CloudInit.writeSeed(account: account, userData: nil, hostname: "original", to: source)

        try CloudInit.copySeed(from: source, to: copy, hostname: "clone")

        let before = try ISOImage.files(in: Data(contentsOf: source))
        let after = try ISOImage.files(in: Data(contentsOf: copy))
        #expect(after["user-data"] == before["user-data"])
        #expect(after["network-config"].map { String(decoding: $0, as: UTF8.self) } == CloudInit.networkConfig)
        let metaData = try #require(after["meta-data"].map { String(decoding: $0, as: UTF8.self) })
        #expect(metaData.contains("local-hostname: \"clone\""))
        #expect(metaData != before["meta-data"].map { String(decoding: $0, as: UTF8.self) })
        #expect(throws: (any Error).self) { try ISOImage.files(in: Data(count: 4096)) }
    }

    @Test func isoImagesFollowTheStandardLayout() throws {
        let big = Data(repeating: 0x41, count: 5000)

        let image = try ISOImage.make(files: [("user-data", big), ("meta-data", Data("x".utf8))], volume: "cidata")

        #expect(image.count % ISOImage.sectorSize == 0)
        #expect(image[16 * 2048] == 1)
        #expect(image[16 * 2048 + 1..<16 * 2048 + 6] == Data("CD001".utf8))
        #expect(image[17 * 2048] == 255)
        #expect(UInt32(image[16 * 2048 + 80]) | UInt32(image[16 * 2048 + 81]) << 8 == UInt32(image.count / 2048))
        let files = try isoFiles(image)
        #expect(files["USER-DATA;1"] == big)
        #expect(files["META-DATA;1"] == Data("x".utf8))
    }

    @Test func aRecordCutOffAtTheSectorEndIsRefused() throws {
        let image = try ISOImage.make(
            files: [("user-data", Data("u".utf8)), ("meta-data", Data("m".utf8))], volume: "cidata")
        let bytes = [UInt8](image)
        let rootRecord = 16 * 2048 + 156
        let root =
            (Int(bytes[rootRecord + 2]) | Int(bytes[rootRecord + 3]) << 8 | Int(bytes[rootRecord + 4]) << 16) * 2048
        var offset = root
        while bytes[offset] > 0 { offset += Int(bytes[offset]) }
        var cut = Data(image.prefix(root + 2048))
        cut[offset] = 40
        for index in (offset + 1)..<(root + 2048) { cut[index] = 0 }

        #expect(throws: HangarError.self) { try ISOImage.files(in: cut) }
        cut[root + 2047] = 40
        #expect(throws: HangarError.self) { try ISOImage.files(in: cut) }
        #expect(try ISOImage.files(in: image)["user-data"] == Data("u".utf8))
    }

    private func isoFiles(_ image: Data) throws -> [String: Data] {
        let bytes = [UInt8](image)
        func le32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3])
                << 24
        }
        let rootRecord = 16 * 2048 + 156
        let root = le32(rootRecord + 2) * 2048
        var files: [String: Data] = [:]
        var offset = root
        while bytes[offset] > 0 {
            let length = Int(bytes[offset])
            let nameLength = Int(bytes[offset + 32])
            let name = String(decoding: bytes[offset + 33..<offset + 33 + nameLength], as: UTF8.self)
            if bytes[offset + 25] & 2 == 0 {
                let start = le32(offset + 2) * 2048
                files[name] = Data(bytes[start..<start + le32(offset + 10)])
            }
            offset += length
        }
        return files
    }
}
