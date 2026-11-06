import Compression

package enum CompressedData {
    package static func decode(
        _ source: UnsafeRawBufferPointer, into target: UnsafeMutableRawBufferPointer,
        using algorithm: compression_algorithm
    ) -> Int {
        let input = source.bindMemory(to: UInt8.self)
        let output = target.bindMemory(to: UInt8.self)
        guard let inputStart = input.baseAddress, let outputStart = output.baseAddress else { return 0 }
        return compression_decode_buffer(outputStart, output.count, inputStart, input.count, nil, algorithm)
    }
}
