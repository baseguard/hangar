import System

extension FileDescriptor {
    package func readFully(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        var done = 0
        while done < buffer.count {
            let rest = UnsafeMutableRawBufferPointer(rebasing: buffer[done...])
            let count = try read(fromAbsoluteOffset: offset + Int64(done), into: rest)
            if count == 0 { break }
            done += count
        }
        return done
    }
}
