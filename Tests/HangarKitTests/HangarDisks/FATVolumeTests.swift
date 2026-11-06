import Foundation
import HangarDisks
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.serialized, .temporaryHangarHome)
struct FATVolumeTests {
    /// A real FAT32 volume made by macOS, the slowest part of these tests, so each test makes one.
    private func makeMedia(status: String, log: String = "") throws -> URL {
        let url = HangarPaths.home.appendingPathComponent("install.img")
        try SparseFile.create(at: url, size: 64 << 20)
        let blank = try DiskImage.attach(url, readOnly: false, mount: false)
        do {
            try ProcessUtil.run(
                "/usr/sbin/diskutil",
                [
                    "partitionDisk", blank.device, "1", "MBR", "FAT32", "HANGAR", "R",
                ])
        } catch {
            blank.detach()
            throw error
        }
        blank.detach()

        let media = try DiskImage.attach(url, readOnly: false)
        defer { media.detach() }
        let boot = try #require(media.volumes["msdos"])
        let files = FileManager.default
        let hangar = boot.appendingPathComponent("hangar")
        try files.createDirectory(at: hangar, withIntermediateDirectories: true)
        try Data(status.utf8).write(to: hangar.appendingPathComponent("status"))
        try Data(log.utf8).write(to: hangar.appendingPathComponent("install.log"))
        let logs = boot.appendingPathComponent("LOGS")
        try files.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("short".utf8).write(to: logs.appendingPathComponent("A.TXT"))
        try Data("long".utf8).write(to: logs.appendingPathComponent("a long file name.txt"))
        try Data(repeating: 0x41, count: 300_000).write(to: logs.appendingPathComponent("big.bin"))
        try ProcessUtil.run("/usr/sbin/dot_clean", ["-m", boot.path])
        return url
    }

    private func partitionOffset(of url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 446 + 8)
        let bytes = try #require(try handle.read(upToCount: 4))
        return (UInt64(bytes[0]) | UInt64(bytes[1]) << 8 | UInt64(bytes[2]) << 16 | UInt64(bytes[3]) << 24) * 512
    }

    private func patch(_ url: URL, at offset: UInt64, with bytes: [UInt8]) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(bytes))
    }

    @Test func filesAreReadFromTheRawImageAndCorruptImagesAreRefused() throws {
        let good = try makeMedia(status: "OK\r\n", log: "line 1\r\nline 2\r\n")
        let volume = try FATVolume(image: good)
        defer { volume.close() }

        #expect(try volume.readFile(["hangar", "status"], limit: 256) == Data("OK\r\n".utf8))
        #expect(try volume.readFile(["HANGAR", "INSTALL.LOG"], limit: 1 << 20) == Data("line 1\r\nline 2\r\n".utf8))
        #expect(try volume.readFile(["logs", "a.txt"], limit: 256) == Data("short".utf8))
        #expect(try volume.readFile(["logs", "A Long File Name.txt"], limit: 256) == Data("long".utf8))
        #expect(try volume.readFile(["logs", "big.bin"], limit: 1 << 20)?.count == 300_000)
        #expect(try volume.readFile(["logs", "big.bin"], limit: 1000)?.count == 1000)
        #expect(try volume.readFile(["hangar", "missing"], limit: 256) == nil)
        #expect(try volume.readFile(["nowhere", "status"], limit: 256) == nil)
        #expect(try volume.readFile(["hangar"], limit: 256) == nil)
        try WindowsMedia.checkResult(good)

        try expectCorruptCopiesRefused(of: good)
    }

    @Test func installationFailuresAreReportedFromTheLog() throws {
        let failed = try makeMedia(status: "FAILED\r\n", log: (1...20).map { "step \($0)" }.joined(separator: "\r\n"))

        #expect(throws: HangarError.self) { try WindowsMedia.checkResult(failed) }
        do {
            try WindowsMedia.checkResult(failed)
        } catch {
            #expect(error.localizedDescription.hasPrefix("Windows installation failed:\nstep 6\n"))
            #expect(error.localizedDescription.hasSuffix("step 20"))
        }
    }

    private func expectCorruptCopiesRefused(of good: URL) throws {
        let partition = try partitionOffset(of: good)

        func corrupted(_ name: String, _ change: (URL) throws -> Void) throws -> URL {
            let copy = HangarPaths.home.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: good, to: copy)
            try change(copy)
            return copy
        }

        let zeroSectors = try corrupted("sectors.img") { try patch($0, at: partition + 11, with: [0, 0]) }
        #expect(throws: HangarError.self) { try FATVolume(image: zeroSectors) }

        let farPartition = try corrupted("far.img") { try patch($0, at: 446 + 8, with: [0xFF, 0xFF, 0xFF, 0x7F]) }
        #expect(throws: HangarError.self) { try FATVolume(image: farPartition) }

        let noTable = try corrupted("table.img") { try patch($0, at: 510, with: [0, 0]) }
        #expect(throws: HangarError.self) { try FATVolume(image: noTable) }

        let truncated = try corrupted("short.img") { try FileHandle(forUpdating: $0).truncate(atOffset: 1024) }
        #expect(throws: HangarError.self) { try FATVolume(image: truncated) }

        let looping = try corrupted("loop.img") { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: partition)
            let bpb = try #require(try handle.read(upToCount: 512))
            let bytesPerSector = UInt64(bpb[11]) | UInt64(bpb[12]) << 8
            let reserved = UInt64(bpb[14]) | UInt64(bpb[15]) << 8
            let root = UInt64(bpb[44]) | UInt64(bpb[45]) << 8 | UInt64(bpb[46]) << 16 | UInt64(bpb[47]) << 24
            let entry = partition + reserved * bytesPerSector + root * 4
            try patch(
                url, at: entry,
                with: [UInt8(root & 0xFF), UInt8(root >> 8 & 0xFF), UInt8(root >> 16 & 0xFF), UInt8(root >> 24 & 0x0F)])
        }
        let volume = try FATVolume(image: looping)
        defer { volume.close() }
        #expect(throws: HangarError.self) { try volume.readFile(["hangar", "status"], limit: 256) }

        let endlessName = try corrupted("name.img") { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: partition)
            let bpb = try #require(try handle.read(upToCount: 512))
            let bytesPerSector = UInt64(bpb[11]) | UInt64(bpb[12]) << 8
            let reserved = UInt64(bpb[14]) | UInt64(bpb[15]) << 8
            let fatSize = UInt64(bpb[36]) | UInt64(bpb[37]) << 8 | UInt64(bpb[38]) << 16 | UInt64(bpb[39]) << 24
            let root = UInt64(bpb[44]) | UInt64(bpb[45]) << 8 | UInt64(bpb[46]) << 16 | UInt64(bpb[47]) << 24
            let rootDirectory =
                partition + (reserved + UInt64(bpb[16]) * fatSize + (root - 2) * UInt64(bpb[13])) * bytesPerSector
            let nameEntry: [UInt8] =
                [0x41] + Array(repeating: [0x41, 0], count: 5).joined() + [0x0F, 0, 0]
                + Array(repeating: [0x41, 0], count: 6).joined() + [0, 0]
                + Array(repeating: [0x41, 0], count: 2).joined()
            // A cluster holds 16 entries here, so the root folder gets a second cluster for 21 name parts.
            let next = root + 1
            try patch(
                url, at: partition + reserved * bytesPerSector + root * 4,
                with: [
                    UInt8(next & 0xFF), UInt8(next >> 8 & 0xFF), UInt8(next >> 16 & 0xFF), 0, 0xFF, 0xFF, 0xFF, 0x0F,
                ])
            try patch(url, at: rootDirectory, with: Array(repeating: nameEntry, count: 21).joined().map { $0 })
        }
        let named = try FATVolume(image: endlessName)
        defer { named.close() }
        #expect(
            failureMessage { _ = try named.readFile(["hangar", "status"], limit: 256) }
                == "Could not read the Windows installation media: a file name is too long.")
    }
}
