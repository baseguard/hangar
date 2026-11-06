/// The ICMP message types (RFC 792) the inspector tells apart.
package enum ICMPType {
    package static let echoReply: UInt8 = 0
    package static let destinationUnreachable: UInt8 = 3
    package static let echoRequest: UInt8 = 8
    package static let timeExceeded: UInt8 = 11
    package static let parameterProblem: UInt8 = 12
}
