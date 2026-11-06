import Foundation
import Testing

@testable import HangarPackets
@testable import HangarTraffic

/// The guest's HTTPS to a host with a secret goes to the secrets proxy and back, frame by frame.
struct TrafficInspectorSecretsTests {
    private let subnet = IPv4Subnet(gateway: IPv4Address(10, 88, 0, 1), prefixLength: 24)
    private let guestMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x10]
    private let gatewayMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x01]
    private let guestIP = IPv4Address(10, 88, 0, 10).value
    private let github = IPv4Address(140, 82, 121, 4).value
    private let proxy = TCPRedirect.Endpoint(address: IPv4Address(10, 88, 0, 1).value, port: 61_000)
    private let connections = DivertedConnections()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inspector() -> TrafficInspector {
        let inspector = TrafficInspector(
            guestMAC: guestMAC, guestIP: guestIP, subnet: subnet, gatewayMAC: gatewayMAC,
            serverMAC: [0x02, 0, 0, 0, 0, 0x02], policy: TrafficPolicy())
        inspector.useSecrets(
            for: ["api.github.com"], proxy: SecretsDiversion(endpoint: proxy, connections: connections))
        return inspector
    }

    private func frame(from source: UInt32, to destination: UInt32, _ protocolNumber: UInt8, _ transport: [UInt8])
        -> [UInt8]
    {
        let fromGuest = source == guestIP
        return Packet.ethernet(
            destination: fromGuest ? gatewayMAC : guestMAC, source: fromGuest ? guestMAC : gatewayMAC,
            type: Packet.etherTypeIPv4,
            payload: Packet.ipv4(source: source, destination: destination, protocol: protocolNumber, payload: transport)
        )
    }

    private func guestSYN(to destination: UInt32, port: UInt16 = 443) -> [UInt8] {
        frame(
            from: guestIP, to: destination, Packet.protocolTCP,
            Packet.tcp(
                source: guestIP, destination: destination, sourcePort: 50_000, destinationPort: port, sequence: 1000,
                acknowledgment: 0, flags: TCPSegment.syn))
    }

    private func resolve(_ inspector: TrafficInspector, _ name: String, to address: String) {
        let query = TrafficSamples.dnsQuery(name)
        _ = inspector.fromGuest(
            frame(
                from: guestIP, to: subnet.gateway.value, Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)
        _ = inspector.fromNetwork(
            frame(
                from: subnet.gateway.value, to: guestIP, Packet.protocolUDP,
                Packet.udp(
                    sourcePort: 53, destinationPort: 40_000,
                    payload: TrafficSamples.dnsAnswer(to: query, addresses: [address]))), now: now)
    }

    private func tcp(in frame: [UInt8]) throws -> TCPSegment {
        try #require(IPv4Packet(frame, offset: 14).flatMap(TCPSegment.init))
    }

    @Test func httpsToAHostWithASecretGoesToTheProxy() throws {
        let watcher = inspector()
        resolve(watcher, "api.github.com", to: "140.82.121.4")

        let output = watcher.fromGuest(guestSYN(to: github), now: now)

        let sent = try tcp(in: try #require(output.toNetwork.first))
        #expect(TCPRedirect.Endpoint(address: sent.ip.destination, port: sent.destinationPort) == proxy)
        #expect(Packet.checksum(sent.ip.bytes[sent.ip.offset..<sent.ip.payloadOffset]) == 0)
        let guest = TCPRedirect.Endpoint(address: guestIP, port: 50_000)
        #expect(connections.take(guest, now: now)?.server == TCPRedirect.Endpoint(address: github, port: 443))
        #expect(connections.take(guest, now: now) == nil)
    }

    /// The resolver gives names lowercased, so a guest asking in capitals still reaches the proxy and gets no HTTPS
    /// record.
    @Test func aHostWithASecretIsKnownWhateverCaseTheGuestUses() throws {
        let watcher = inspector()
        resolve(watcher, "API.GitHub.COM", to: "140.82.121.4")
        let query = TrafficSamples.dnsQuery("API.GITHUB.COM", id: 0x78, type: DNSMessage.typeHTTPS)
        let lookup = frame(
            from: guestIP, to: subnet.gateway.value, Packet.protocolUDP,
            Packet.udp(sourcePort: 40_001, destinationPort: 53, payload: query))

        let output = watcher.fromGuest(guestSYN(to: github), now: now)
        let lookedUp = watcher.fromGuest(lookup, now: now)

        let sent = try tcp(in: try #require(output.toNetwork.first))
        #expect(TCPRedirect.Endpoint(address: sent.ip.destination, port: sent.destinationPort) == proxy)
        let guest = TCPRedirect.Endpoint(address: guestIP, port: 50_000)
        #expect(connections.take(guest, now: now)?.names == ["api.github.com"])
        #expect(lookedUp.toNetwork.isEmpty)
    }

    @Test func theProxysAnswerLooksLikeTheServers() throws {
        let watcher = inspector()
        resolve(watcher, "api.github.com", to: "140.82.121.4")
        _ = watcher.fromGuest(guestSYN(to: github), now: now)
        let synAck = frame(
            from: proxy.address, to: guestIP, Packet.protocolTCP,
            Packet.tcp(
                source: proxy.address, destination: guestIP, sourcePort: proxy.port, destinationPort: 50_000,
                sequence: 7000, acknowledgment: 1001, flags: TCPSegment.syn | TCPSegment.ack))

        let output = watcher.fromNetwork(synAck, now: now)

        let delivered = try tcp(in: try #require(output.toGuest.first))
        #expect(delivered.ip.source == github)
        #expect(delivered.sourcePort == 443)
    }

    @Test func otherHostsAndPortsGoToTheirServer() throws {
        let watcher = inspector()
        resolve(watcher, "github.com", to: "140.82.121.4")

        let https = watcher.fromGuest(guestSYN(to: github), now: now)
        let plain = watcher.fromGuest(guestSYN(to: github, port: 80), now: now)

        #expect(try tcp(in: try #require(https.toNetwork.first)).ip.destination == github)
        #expect(try tcp(in: try #require(plain.toNetwork.first)).ip.destination == github)
    }

    @Test func theGuestCantReachTheProxyDirectlyNorGetItsUnaskedFrames() throws {
        let watcher = inspector()
        let direct = watcher.fromGuest(guestSYN(to: proxy.address, port: proxy.port), now: now)
        let unasked = frame(
            from: proxy.address, to: guestIP, Packet.protocolTCP,
            Packet.tcp(
                source: proxy.address, destination: guestIP, sourcePort: proxy.port, destinationPort: 50_001,
                sequence: 1, acknowledgment: 1, flags: TCPSegment.ack))

        #expect(direct.toNetwork.isEmpty)
        #expect(watcher.fromNetwork(unasked, now: now).toGuest.isEmpty)
    }

    @Test func quicAndServiceRecordsForAHostWithASecretAreDropped() throws {
        let watcher = inspector()
        resolve(watcher, "api.github.com", to: "140.82.121.4")
        let quic = frame(
            from: guestIP, to: github, Packet.protocolUDP,
            Packet.udp(sourcePort: 50_002, destinationPort: 443, payload: [0xc0, 0, 0, 0, 1]))
        let query = TrafficSamples.dnsQuery("api.github.com", id: 0x77, type: DNSMessage.typeHTTPS)
        let lookup = frame(
            from: guestIP, to: subnet.gateway.value, Packet.protocolUDP,
            Packet.udp(sourcePort: 40_001, destinationPort: 53, payload: query))

        let lookedUp = watcher.fromGuest(lookup, now: now)

        #expect(watcher.fromGuest(quic, now: now).toNetwork.isEmpty)
        #expect(lookedUp.toNetwork.isEmpty)
        let reply = try #require(
            lookedUp.toGuest.first.flatMap { IPv4Packet($0, offset: 14) }.flatMap(UDPDatagram.init))
        #expect(DNSMessage(Array(reply.ip.bytes[reply.payload]))?.id == 0x77)
    }
}
