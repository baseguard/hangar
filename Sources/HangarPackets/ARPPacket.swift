/// An ARP message for IPv4 over Ethernet, read from a whole Ethernet frame; other kinds of ARP read as nil.
package struct ARPPacket {
    package static let request: UInt16 = 1
    package static let reply: UInt16 = 2

    package let operation: UInt16
    package let senderMAC: [UInt8]
    package let senderIP: UInt32
    package let targetMAC: [UInt8]
    package let targetIP: UInt32

    package init?(_ frame: [UInt8]) {
        guard frame.count >= 42, Packet.readUInt16(frame, at: 14) == 1,
            Packet.readUInt16(frame, at: 16) == Packet.etherTypeIPv4, frame[18] == 6, frame[19] == 4
        else { return nil }
        operation = Packet.readUInt16(frame, at: 20)
        senderMAC = Array(frame[22..<28])
        senderIP = Packet.readUInt32(frame, at: 28)
        targetMAC = Array(frame[32..<38])
        targetIP = Packet.readUInt32(frame, at: 38)
    }
}
