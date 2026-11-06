import Foundation
import HangarDisks
import HangarSupport
import HangarTraffic
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct VMImageFormatTests {
    private func manifest(parts: [(offset: UInt64, length: Int)]) -> VMImage.Manifest {
        let digest = VMImage.digest(of: Data())
        return VMImage.Manifest(
            config: VMImage.Descriptor(mediaType: VMImage.imageConfigType, digest: digest, size: 100),
            layers: [
                VMImage.Descriptor(mediaType: VMImage.configType, digest: digest, size: 100),
                VMImage.Descriptor(mediaType: VMImage.nvramType, digest: digest, size: 10),
            ]
                + parts.map {
                    VMImage.Descriptor(
                        mediaType: VMImage.diskType, digest: digest, size: 100,
                        annotations: [
                            VMImage.offsetKey: String($0.offset), VMImage.lengthKey: String($0.length),
                            VMImage.plainDigestKey: digest,
                        ])
                })
    }

    @Test func imageSettingsMustFitTheirOS() throws {
        let details = VMImage.MacDetails(
            version: "27.0.1", build: "26A434", xcode: nil, hardwareModel: try TestVM.hardwareModel,
            minimumCPUCount: 2, minimumMemorySize: 4 << 30)
        let layout = try VMImage.Layout(manifest(parts: []))

        try layout.check(VMImage.Config(os: .linux, diskSize: 8 << 20, account: "dev", macOS: nil))
        try layout.check(VMImage.Config(os: .macOS, diskSize: 8 << 20, account: nil, macOS: details))
        #expect(throws: (any Error).self) {
            try layout.check(VMImage.Config(os: .linux, diskSize: 8 << 20, macOS: details))
        }
        #expect(throws: (any Error).self) {
            try layout.check(VMImage.Config(os: .windows, diskSize: 8 << 20, macOS: details))
        }
        #expect(throws: (any Error).self) {
            try layout.check(VMImage.Config(os: .macOS, diskSize: 8 << 20, macOS: nil))
        }
        #expect(throws: (any Error).self) {
            try layout.check(VMImage.Config(os: .linux, diskSize: 8 << 20, account: "-x"))
        }
        #expect(throws: (any Error).self) {
            try layout.check(VMImage.Config(os: .linux, diskSize: 8 << 20, remoteDesktop: false))
        }
        try layout.check(VMImage.Config(os: .windows, diskSize: 8 << 20, remoteDesktop: false))
    }

    @Test func manifestsMustBeHangarImagesWithTheirSettingsFirst() throws {
        let good = manifest(parts: [(0, 4096)])
        _ = try VMImage.Layout(good)

        var forged = good
        forged.artifactType = nil
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }

        forged = good
        forged.config.mediaType = VMImage.configType
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }

        forged = good
        forged.layers.swapAt(0, 1)
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }

        forged = good
        forged.layers.append(good.layers[0])
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }

        forged = good
        forged.layers.insert(good.layers[1], at: 2)
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }

        forged = good
        forged.layers[0].size = 65_537
        #expect(throws: (any Error).self) { try VMImage.Layout(forged) }
    }

    @Test func manifestsWithPartsOutsideTheDiskAreRefused() throws {
        let config = VMImage.Config(
            os: .macOS, diskSize: 8 << 20,
            macOS: VMImage.MacDetails(
                version: "27.0.1", build: "26A434", hardwareModel: try TestVM.hardwareModel, minimumCPUCount: 2,
                minimumMemorySize: 4 << 30))
        var huge = config
        huge.diskSize = 3 << 40

        try VMImage.Layout(manifest(parts: [(0, 4 << 20), (4 << 20, 4 << 20)])).check(config)
        #expect(throws: (any Error).self) {
            try VMImage.Layout(manifest(parts: [(0, 4 << 20), (4 << 20, 8 << 20)])).check(config)
        }
        #expect(throws: (any Error).self) { try VMImage.Layout(manifest(parts: [(0, 4 << 20), (1 << 20, 1 << 20)])) }
        #expect(throws: (any Error).self) { try VMImage.Layout(manifest(parts: [(0, (512 << 20) + 1)])) }
        #expect(throws: (any Error).self) { try VMImage.Layout(manifest(parts: [(100, 4096)])) }
        #expect(throws: (any Error).self) { try VMImage.Layout(manifest(parts: [(UInt64.max - 4095, 4096)])) }
        #expect(throws: (any Error).self) {
            try VMImage.Layout(manifest(parts: [(0, 4096), (UInt64.max - 4095, 4096)]))
        }
        #expect(throws: (any Error).self) { try VMImage.Layout(manifest(parts: [(0, 4096)])).check(huge) }
    }

    @Test func imagesCannotSetAnythingButTheMachine() throws {
        let hardwareModel = try TestVM.hardwareModel
        let json = """
            {"os":"macos","diskSize":85899345920,"macOS":{"version":"27.0.1","build":"26A434","minimumCPUCount":2,
             "hardwareModel":"\(hardwareModel.base64EncodedString())","minimumMemorySize":4294967296},"machineIdentifier":"AAAA",
             "macAddress":"02:00:00:00:00:01","provisioning":{"username":"x"},"sharedFolders":[{"name":"root","path":"/"}],"sshUser":"x",
             "autoStart":true,"traffic":{"mode":"off"},"network":{"mode":"nat"},"isoPath":"/etc/passwd"}
            """
        let image = try JSONDecoder().decode(VMImage.Config.self, from: Data(json.utf8))

        let config = try VMImage.vmConfig(image, options: CreateOptions(diskSize: 80 << 30))

        #expect(config.sharedFolders.isEmpty)
        #expect(config.sshUser == nil)
        #expect(config.isoPath == nil)
        #expect(config.network.mode == .managed)
        #expect(config.traffic == TrafficPolicy())
        #expect(config.hardwareModel == hardwareModel)
        #expect(config.machineIdentifier != nil && config.machineIdentifier != Data(base64Encoded: "AAAA"))
        #expect(config.network.macAddress != "02:00:00:00:00:01")
        #expect(config.provisioning == nil)
    }

    @Test func partsUnpackToExactlyTheirLength() throws {
        let plain = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        let disk = HangarPaths.home.appendingPathComponent("disk")
        let part = HangarPaths.home.appendingPathComponent("part")
        let garbage = HangarPaths.home.appendingPathComponent("garbage")
        try plain.write(to: disk)
        try Data("not a compressed part".utf8).write(to: garbage)

        let packed = try #require(try VMImage.compress(disk, at: 0, length: plain.count))
        try packed.data.write(to: part)
        var unpacked = Data()
        try VMImage.decode(part, length: plain.count) { unpacked.append($0) }

        #expect(unpacked == plain)
        #expect(packed.plainDigest == VMImage.digest(of: plain))
        #expect(
            failureMessage { try VMImage.decode(part, length: plain.count - 1) { _ in } }
                == "A disk part unpacked to more than 2999999 bytes.")
        #expect(
            failureMessage { try VMImage.decode(part, length: plain.count + 1) { _ in } }
                == "A disk part unpacked to 3000000 bytes instead of 3000001.")
        #expect(
            failureMessage { try VMImage.decode(garbage, length: plain.count) { _ in } }
                == "A disk part isn't compressed the way Hangar images are.")
    }

    @Test func emptyRegionsAreNotPacked() throws {
        let disk = HangarPaths.home.appendingPathComponent("disk")
        try SparseFile.create(at: disk, size: 8 << 20)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: 6 << 20)
        try handle.write(contentsOf: Data(count: 1 << 20))
        try handle.close()

        let hole = try VMImage.compress(disk, at: 0, length: 4 << 20)
        let zeros = try VMImage.compress(disk, at: 4 << 20, length: 4 << 20)

        #expect(hole == nil)
        #expect(zeros == nil)
    }
}
