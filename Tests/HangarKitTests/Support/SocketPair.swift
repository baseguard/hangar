import Darwin
import Testing

/// Two connected sockets: one end for the Mac's side, the other for a fake guest.
func makeSocketPair() throws -> (Int32, Int32) {
    var ends: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
    return (ends[0], ends[1])
}
