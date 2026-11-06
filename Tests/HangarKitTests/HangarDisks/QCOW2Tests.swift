import Compression
import Foundation
import HangarSupport
import Testing

@testable import HangarDisks

@Suite(.temporaryHangarHome)
struct QCOW2Tests {
    private let mib = 1 << 20

    private func compress(_ data: Data, _ algorithm: Algorithm) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: algorithm) { if let chunk = $0 { output.append(chunk) } }
        try filter.write(data)
        try filter.finalize()
        return output
    }

    private func write(_ data: Data, as name: String = UUID().uuidString) throws -> URL {
        let url = HangarPaths.isoCache.appendingPathComponent(name)
        try HangarPaths.createDirectory(HangarPaths.isoCache)
        try data.write(to: url)
        return url
    }

    private func qcow2(
        size: UInt64, data: [Int: Data], compressed: [Int: Data], zeros: [Int] = [],
        tweak: (inout [UInt8]) -> Void = { _ in }
    ) throws -> Data {
        let clusterBits = 16
        let clusterSize = 1 << clusterBits
        var file = [UInt8](repeating: 0, count: 3 * clusterSize)
        func put(_ value: UInt64, at offset: Int, width: Int) {
            for index in 0..<width {
                file[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64((width - 1 - index) * 8))
            }
        }
        file.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xFB])
        put(3, at: 4, width: 4)
        put(UInt64(clusterBits), at: 20, width: 4)
        put(size, at: 24, width: 8)
        put(1, at: 36, width: 4)
        put(UInt64(clusterSize), at: 40, width: 8)
        put(4, at: 96, width: 4)
        put(104, at: 100, width: 4)
        put(UInt64(2 * clusterSize) | 1 << 63, at: clusterSize, width: 8)
        for (index, bytes) in data.sorted(by: { $0.key < $1.key }) {
            let host = file.count
            file += Array(bytes) + [UInt8](repeating: 0, count: clusterSize - bytes.count)
            put(UInt64(host) | 1 << 63, at: 2 * clusterSize + index * 8, width: 8)
        }
        for (index, bytes) in compressed.sorted(by: { $0.key < $1.key }) {
            let packed = [UInt8](try compress(bytes, .zlib))
            let host = file.count + 100
            file += [UInt8](repeating: 0, count: 100) + packed
            let shift = 62 - (clusterBits - 8)
            let sectors = UInt64((host % 512 + packed.count + 511) / 512)
            put(UInt64(host) | (sectors - 1) << UInt64(shift) | 1 << 62, at: 2 * clusterSize + index * 8, width: 8)
        }
        for index in zeros { put(1, at: 2 * clusterSize + index * 8, width: 8) }
        tweak(&file)
        return Data(file)
    }

    @Test func qcow2ImagesBecomeSparseRawDisks() throws {
        let size = UInt64(64 * mib)
        let first = Data(repeating: 0x11, count: 1 << 16)
        let middle = Data((0..<(1 << 16)).map { UInt8($0 % 251) })
        let image = try qcow2(size: size, data: [0: first], compressed: [700: middle], zeros: [5])
        let source = try write(image)
        let output = HangarPaths.isoCache.appendingPathComponent(UUID().uuidString + ".raw")
        #expect(QCOW2.isImage(source))

        try QCOW2.convert(source, to: output) { _ in }

        var expected = Data(count: Int(size))
        expected.replaceSubrange(0..<(1 << 16), with: first)
        expected.replaceSubrange((700 << 16)..<(701 << 16), with: middle)
        #expect(try Data(contentsOf: output) == expected)
        var info = stat()
        #expect(stat(output.path, &info) == 0)
        #expect(Int(info.st_blocks) * 512 < Int(size) / 4)

        let refused: [(tweak: (inout [UInt8]) -> Void, refusal: String)] = [
            ({ $0[15] = 1 }, "disk.qcow2 needs a backing file; use a standalone image."),
            ({ $0[35] = 1 }, "disk.qcow2 is encrypted."),
            ({ $0[79] = 0x10 }, "disk.qcow2 uses qcow2 features Hangar can't read."),
            ({ $0[7] = 4 }, "disk.qcow2 uses qcow2 version 4, which Hangar can't read."),
        ]
        for (tweak, refusal) in refused {
            let bad = try write(
                try qcow2(size: size, data: [0: first], compressed: [:], tweak: tweak), as: "disk.qcow2")
            #expect(failureMessage { try QCOW2.convert(bad, to: output) { _ in } } == refusal)
        }
    }
}
