import Foundation

extension FileHandle {
    /// Each read hands back autoreleased data. A loop on a thread with no pool of its own, as in Swift
    /// concurrency, would otherwise keep every piece it read until the loop ends: a whole ISO, for one.
    package func readPiece(upToCount count: Int) throws -> Data? {
        try autoreleasepool { try read(upToCount: count) }
    }
}
