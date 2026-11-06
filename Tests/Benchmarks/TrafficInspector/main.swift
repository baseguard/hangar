// Feeds connections through TrafficInspector the way a guest browsing an allow-listed site does, and prints the
// cost per frame; `make bench` builds it against Release libraries. ROUNDS sets the number of connections.
import Foundation
import HangarPackets
import HangarTraffic

let guestMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x10]
let gatewayMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x01]
let serverMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x02]
let subnet = IPv4Subnet(gateway: IPv4Address(10, 88, 0, 1), prefixLength: 24)
let guestIP = IPv4Address(10, 88, 0, 10).value
let gateway = subnet.gateway.value

struct Frame {
    let isFromGuest: Bool
    let bytes: [UInt8]
}

func fromGuest(to destination: UInt32, _ protocolNumber: UInt8, _ transport: [UInt8]) -> Frame {
    let packet = Packet.ipv4(source: guestIP, destination: destination, protocol: protocolNumber, payload: transport)
    let bytes = Packet.ethernet(
        destination: gatewayMAC, source: guestMAC, type: Packet.etherTypeIPv4, payload: packet)
    return Frame(isFromGuest: true, bytes: bytes)
}

func fromNetwork(_ source: UInt32, _ protocolNumber: UInt8, _ transport: [UInt8]) -> Frame {
    let packet = Packet.ipv4(source: source, destination: guestIP, protocol: protocolNumber, payload: transport)
    let bytes = Packet.ethernet(
        destination: guestMAC, source: gatewayMAC, type: Packet.etherTypeIPv4, payload: packet)
    return Frame(isFromGuest: false, bytes: bytes)
}

func dnsQuery(_ name: String, id: UInt16) -> [UInt8] {
    let labels: [UInt8] = name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    return [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + labels + [0, 1, 0, 1]
}

func dnsAnswer(to query: [UInt8], address: UInt32) -> [UInt8] {
    var answer = query
    answer[2] = 0x81
    answer[3] = 0x80
    answer[7] = 1
    let addressBytes = [
        UInt8(address >> 24), UInt8(address >> 16 & 0xff), UInt8(address >> 8 & 0xff), UInt8(address & 0xff),
    ]
    return answer + [0xc0, 12, 0, 1, 0, 1, 0, 0, 0x0e, 0x10, 0, 4] + addressBytes
}

/// One allowed visit: a lookup, the handshake, a request, four 1200-byte replies and the close.
func connection(_ index: Int) -> [Frame] {
    let host = "host\(index % 200).example.com"
    let server = IPv4Address(93, 184, UInt8(index % 200), 34).value
    let port = UInt16(20_000 + index % 40_000)
    let query = dnsQuery(host, id: UInt16(index & 0xffff))
    let request = Array("GET /index.html HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: bench\r\n\r\n".utf8)
    let requestEnd = 1001 + UInt32(request.count)
    let body = [UInt8](repeating: 0x41, count: 1200)

    func guestTCP(sequence: UInt32, acknowledgment: UInt32, flags: UInt8, _ payload: [UInt8] = []) -> Frame {
        fromGuest(
            to: server, Packet.protocolTCP,
            Packet.tcp(
                source: guestIP, destination: server, sourcePort: port, destinationPort: 80, sequence: sequence,
                acknowledgment: acknowledgment, flags: flags, payload: payload))
    }
    func serverTCP(sequence: UInt32, acknowledgment: UInt32, flags: UInt8, _ payload: [UInt8] = []) -> Frame {
        fromNetwork(
            server, Packet.protocolTCP,
            Packet.tcp(
                source: server, destination: guestIP, sourcePort: 80, destinationPort: port, sequence: sequence,
                acknowledgment: acknowledgment, flags: flags, payload: payload))
    }

    var frames = [
        fromGuest(to: gateway, Packet.protocolUDP, Packet.udp(sourcePort: port, destinationPort: 53, payload: query)),
        fromNetwork(
            gateway, Packet.protocolUDP,
            Packet.udp(sourcePort: 53, destinationPort: port, payload: dnsAnswer(to: query, address: server))),
        guestTCP(sequence: 1000, acknowledgment: 0, flags: TCPSegment.syn),
        serverTCP(sequence: 5000, acknowledgment: 1001, flags: TCPSegment.syn | TCPSegment.ack),
        guestTCP(sequence: 1001, acknowledgment: 5001, flags: TCPSegment.ack, request),
    ]
    for part in 0..<4 {
        let sequence = 5001 + UInt32(part * body.count)
        frames.append(serverTCP(sequence: sequence, acknowledgment: requestEnd, flags: TCPSegment.ack, body))
    }
    frames.append(guestTCP(sequence: requestEnd, acknowledgment: 5001 + 4800, flags: TCPSegment.ack | TCPSegment.fin))
    return frames
}

let connectionCount = Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "") ?? 20_000
let connections = (0..<connectionCount).map(connection)
let frameCount = connections.reduce(0) { $0 + $1.count }
var best = Duration.seconds(1000)

// The first run warms the caches and is left out.
for run in 0..<7 {
    let inspector = TrafficInspector(
        guestMAC: guestMAC, guestIP: guestIP, subnet: subnet, gatewayMAC: gatewayMAC, serverMAC: serverMAC,
        policy: TrafficPolicy(mode: .allowlist, allowed: ["*.example.com"]))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    _ = inspector.start(now: start)
    var passed = 0

    let elapsed = ContinuousClock().measure {
        for (index, frames) in connections.enumerated() {
            let now = start.addingTimeInterval(Double(index) / 100)
            for frame in frames {
                let output =
                    frame.isFromGuest
                    ? inspector.fromGuest(frame.bytes, now: now) : inspector.fromNetwork(frame.bytes, now: now)
                passed += output.toNetwork.count + output.toGuest.count
            }
        }
    }

    if run == 0 { print("frames per run: \(frameCount), passed in the first run: \(passed)") }
    if run > 0 { best = min(best, elapsed) }
}

let seconds = Double(best.components.seconds) + Double(best.components.attoseconds) / 1e18
print(String(format: "best of 6: %.3f s, %.0f ns per frame", seconds, seconds * 1e9 / Double(frameCount)))
