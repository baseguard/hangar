import Foundation
import Testing

@testable import HangarPackets
@testable import HangarTraffic

struct TrafficInspectorTests {
    private let subnet = IPv4Subnet(gateway: IPv4Address(10, 88, 0, 1), prefixLength: 24)
    private let guestMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x10]
    private let gatewayMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x01]
    private let serverMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x02]
    private let guestIP = IPv4Address(10, 88, 0, 10).value
    private let github = "140.82.121.4"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inspector(_ policy: TrafficPolicy, guestIP: UInt32? = nil) -> TrafficInspector {
        TrafficInspector(
            guestMAC: guestMAC, guestIP: guestIP ?? self.guestIP, subnet: subnet, gatewayMAC: gatewayMAC,
            serverMAC: serverMAC, policy: policy)
    }

    private func address(_ text: String) -> UInt32 { ipv4(text).value }

    private func guestFrame(
        to destination: String, _ protocolNumber: UInt8, _ transport: [UInt8], from source: UInt32? = nil
    ) -> [UInt8] {
        Packet.ethernet(
            destination: gatewayMAC, source: guestMAC, type: Packet.etherTypeIPv4,
            payload: Packet.ipv4(
                source: source ?? guestIP, destination: address(destination), protocol: protocolNumber,
                payload: transport))
    }

    private func networkFrame(from source: String, _ protocolNumber: UInt8, _ transport: [UInt8]) -> [UInt8] {
        Packet.ethernet(
            destination: guestMAC, source: gatewayMAC, type: Packet.etherTypeIPv4,
            payload: Packet.ipv4(
                source: address(source), destination: guestIP, protocol: protocolNumber, payload: transport))
    }

    private func guestTCP(
        to destination: String, port: UInt16 = 443, flags: UInt8, sequence: UInt32 = 1000,
        acknowledgment: UInt32 = 0, payload: [UInt8] = []
    ) -> [UInt8] {
        guestFrame(
            to: destination, Packet.protocolTCP,
            Packet.tcp(
                source: guestIP, destination: address(destination), sourcePort: 50_000, destinationPort: port,
                sequence: sequence, acknowledgment: acknowledgment, flags: flags, payload: payload))
    }

    private func resolve(_ inspector: TrafficInspector, _ name: String, to addresses: [String])
        -> TrafficInspector.Output
    {
        let query = TrafficSamples.dnsQuery(name)
        _ = inspector.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)
        return inspector.fromNetwork(
            networkFrame(
                from: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(
                    sourcePort: 53, destinationPort: 40_000,
                    payload: TrafficSamples.dnsAnswer(to: query, addresses: addresses))), now: now)
    }

    private func reset(in frames: [[UInt8]]) -> TCPSegment? {
        frames.lazy.compactMap { IPv4Packet($0, offset: 14).flatMap(TCPSegment.init) }.first { $0.has(TCPSegment.rst) }
    }

    @Test func monitorPassesEverythingAndNamesTheConnection() {
        let watcher = inspector(TrafficPolicy())
        let answer = resolve(watcher, "github.com", to: [github])
        #expect(answer.toGuest.count == 1)
        #expect(answer.events.first?.answers == [github])

        let syn = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        #expect(syn.toNetwork.count == 1)
        #expect(syn.events.isEmpty)

        let hello = watcher.fromGuest(
            guestTCP(
                to: github, flags: TCPSegment.ack | 0x08, sequence: 1001,
                payload: TrafficSamples.clientHello(serverName: "github.com")), now: now)
        #expect(hello.toNetwork.count == 1)
        #expect(hello.events.map(\.kind) == [.connect])
        #expect(hello.events.first?.host == "github.com")
        #expect(hello.events.first?.verdict == .allowed)

        let closed = watcher.finish(now: now.addingTimeInterval(3))
        #expect(closed.events.map(\.kind) == [.close])
        #expect(closed.events.first?.sent == UInt64(TrafficSamples.clientHello(serverName: "github.com").count))
    }

    @Test func allowListAnswersBlockedLookupsItself() throws {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        let query = TrafficSamples.dnsQuery("evil.example", id: 0x4242)

        let output = watcher.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)

        #expect(output.toNetwork.isEmpty)
        let reply = try #require(output.toGuest.first.flatMap { IPv4Packet($0, offset: 14) }.flatMap(UDPDatagram.init))
        let message = try #require(DNSMessage(Array(reply.ip.bytes[reply.payload])))
        #expect(message.id == 0x4242)
        #expect(message.responseCode == DNSMessage.nameError)
        #expect(reply.ip.source == address("10.88.0.1"))
        #expect(output.events.first?.verdict == .blocked)
        #expect(output.events.first?.reason == "evil.example is not allowed")
    }

    @Test func allowListRefusesAddressesWithoutAnAllowedName() throws {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        let output = watcher.fromGuest(guestTCP(to: "1.2.3.4", flags: TCPSegment.syn), now: now)

        #expect(output.toNetwork.isEmpty)
        let refusal = try #require(reset(in: output.toGuest))
        #expect(refusal.acknowledgment == 1001)
        #expect(refusal.ip.source == address("1.2.3.4"))
        #expect(output.events.first?.verdict == .blocked)

        _ = resolve(watcher, "api.github.com", to: [github])
        #expect(watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now).toNetwork.count == 1)
    }

    @Test func allowListCatchesAForeignServerNameOnAnAllowedAddress() throws {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher)

        let output = watcher.fromGuest(
            guestTCP(
                to: github, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 5000,
                payload: TrafficSamples.clientHello(serverName: "evil.example")), now: now)

        #expect(reset(in: output.toGuest)?.sequence == 5000)
        #expect(reset(in: output.toNetwork)?.sequence == 1001)
        #expect(output.events.first?.host == "evil.example")
        #expect(output.events.first?.verdict == .blocked)
    }

    @Test func blockListBlocksNamesAndQUICButNotTheRest() {
        let watcher = inspector(TrafficPolicy(mode: .blocklist, blocked: ["*.evil.example", "6.6.6.0/24"]))
        let lookup = watcher.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(
                    sourcePort: 40_000, destinationPort: 53, payload: TrafficSamples.dnsQuery("cdn.evil.example"))),
            now: now)
        #expect(lookup.toNetwork.isEmpty)
        #expect(lookup.events.first?.reason == "blocked by *.evil.example")

        #expect(
            watcher.fromGuest(guestTCP(to: "6.6.6.6", flags: TCPSegment.syn), now: now).events.first?.reason
                == "blocked by 6.6.6.0/24")
        #expect(watcher.fromGuest(guestTCP(to: "8.8.4.4", flags: TCPSegment.syn), now: now).toNetwork.count == 1)

        let quic = watcher.fromGuest(
            guestFrame(
                to: "8.8.4.4", Packet.protocolUDP,
                Packet.udp(sourcePort: 50_001, destinationPort: 443, payload: [0xc0])), now: now)
        #expect(quic.toNetwork.isEmpty)
        #expect(quic.events.first?.reason == "QUIC is blocked")
    }

    /// Every parser gives names lowercased, so the rules compare them as they come, whatever case the guest used.
    @Test func blockRulesMatchNamesWhateverTheirCase() throws {
        let watcher = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        let lookup = watcher.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: TrafficSamples.dnsQuery("EVIL.Example"))),
            now: now)
        _ = resolve(watcher, "github.com", to: [github])

        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher)
        let sni = hello(watcher, TrafficSamples.clientHello(serverName: "Evil.EXAMPLE"))

        _ = watcher.fromGuest(guestTCP(to: github, port: 80, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher, port: 80)
        let host = watcher.fromGuest(
            guestTCP(
                to: github, port: 80, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 5000,
                payload: Array("GET / HTTP/1.1\r\nHost: EVIL.Example\r\n\r\n".utf8)), now: now)

        #expect(lookup.events.first?.reason == "blocked by evil.example")
        #expect(sni.events.first?.host == "evil.example")
        #expect(sni.events.first?.verdict == .blocked)
        #expect(host.events.first?.host == "evil.example")
        #expect(host.events.first?.verdict == .blocked)
    }

    @Test func rulesProtectTheMacAndOtherVMsButTheMacCanAlwaysReachIn() {
        let watcher = inspector(TrafficPolicy(mode: .blocklist, allowsVMs: false))
        #expect(
            watcher.fromGuest(guestTCP(to: "10.88.0.1", port: 8080, flags: TCPSegment.syn), now: now).events.first?
                .reason == "this Mac is blocked")
        #expect(
            watcher.fromGuest(guestTCP(to: "10.88.0.11", port: 22, flags: TCPSegment.syn), now: now).events.first?
                .reason == "other VMs are blocked")

        let inbound = Packet.tcp(
            source: address("10.88.0.1"), destination: guestIP, sourcePort: 60_000, destinationPort: 22,
            sequence: 1, acknowledgment: 0, flags: TCPSegment.syn)
        let ssh = watcher.fromNetwork(networkFrame(from: "10.88.0.1", Packet.protocolTCP, inbound), now: now)
        #expect(ssh.toGuest.count == 1)
        #expect(ssh.events.first?.direction == "in")
        #expect(ssh.events.first?.port == 22)
    }

    @Test func isolatingStopsOpenConnectionsAtOnce() throws {
        let watcher = inspector(TrafficPolicy())
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let update = watcher.update(TrafficPolicy(isolated: true), now: now)
        #expect(update.events.map(\.kind) == [.policy, .connect])
        #expect(update.events.last?.reason == "isolated (rules changed)")

        let next = watcher.fromGuest(
            guestTCP(to: github, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 7000), now: now)
        #expect(next.toNetwork.isEmpty)
        #expect(reset(in: next.toGuest)?.sequence == 7000)

        let lookup = watcher.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: TrafficSamples.dnsQuery("github.com"))),
            now: now)
        #expect(lookup.toNetwork.isEmpty)
        #expect(lookup.toGuest.count == 1)
    }

    @Test func dropsSpoofingIPv6AndUnknownSources() {
        let watcher = inspector(TrafficPolicy())
        var otherMAC = guestTCP(to: github, flags: TCPSegment.syn)
        otherMAC[11] = 0x99
        #expect(watcher.fromGuest(otherMAC, now: now).toNetwork.isEmpty)

        let otherIP = guestFrame(
            to: github, Packet.protocolUDP, Packet.udp(sourcePort: 1, destinationPort: 2, payload: []),
            from: address("10.88.0.11"))
        #expect(watcher.fromGuest(otherIP, now: now).toNetwork.isEmpty)

        let ipv6 = gatewayMAC + guestMAC + [0x86, 0xdd] + [UInt8](repeating: 0x60, count: 60)
        #expect(watcher.fromGuest(ipv6, now: now).toNetwork.isEmpty)
        #expect(
            watcher.fromNetwork(guestMAC + gatewayMAC + [0x86, 0xdd] + [UInt8](repeating: 0x60, count: 60), now: now)
                .toGuest.isEmpty)
    }

    @Test func groupReportsBeforeAnAddressAreDroppedWithoutASpoofEvent() {
        let watcher = inspector(TrafficPolicy())
        let mdnsReport = guestFrame(to: "224.0.0.251", Packet.protocolIGMP, [0x16, 0, 0, 0, 224, 0, 0, 251], from: 0)
        let udpFromNowhere = guestFrame(
            to: github, Packet.protocolUDP, Packet.udp(sourcePort: 1, destinationPort: 2, payload: []), from: 0)

        let report = watcher.fromGuest(mdnsReport, now: now)
        let spoof = watcher.fromGuest(udpFromNowhere, now: now)

        #expect(report.toNetwork.isEmpty)
        #expect(report.events.isEmpty)
        #expect(spoof.toNetwork.isEmpty)
        #expect(spoof.events.map(\.reason) == ["dropped packets from 0.0.0.0"])
        #expect(spoof.events.map(\.proto) == ["udp"])
    }

    @Test func offRecordsNothingButStillDropsSpoofing() {
        let quiet = inspector(TrafficPolicy(mode: .off))
        #expect(quiet.start(now: now).events.isEmpty)

        let syn = guestTCP(to: github, flags: TCPSegment.syn)
        let sent = quiet.fromGuest(syn, now: now)
        #expect(sent.toNetwork == [syn])
        #expect(sent.events.isEmpty)

        let toNeighbour = guestFrame(
            to: "10.88.0.11", Packet.protocolUDP, Packet.udp(sourcePort: 1, destinationPort: 2, payload: [1]))
        #expect(quiet.fromGuest(toNeighbour, now: now).toNetwork == [toNeighbour])

        let reply = networkFrame(
            from: github, Packet.protocolTCP,
            Packet.tcp(
                source: address(github), destination: guestIP, sourcePort: 443, destinationPort: 50_000,
                sequence: 1, acknowledgment: 1001, flags: TCPSegment.syn | TCPSegment.ack))
        let received = quiet.fromNetwork(reply, now: now)
        #expect(received.toGuest == [reply])
        #expect(received.events.isEmpty)

        let ownRequest = Packet.ethernet(
            destination: Packet.broadcastMAC, source: guestMAC, type: Packet.etherTypeARP,
            payload: Packet.arp(
                operation: 1, senderMAC: guestMAC, senderIP: guestIP,
                targetMAC: [0, 0, 0, 0, 0, 0], targetIP: address("10.88.0.11")))
        #expect(quiet.fromGuest(ownRequest, now: now).toNetwork.count == 1)
        #expect(quiet.flows.isEmpty)
        #expect(quiet.finish(now: now).events.isEmpty)

        func claim(senderMAC: [UInt8], senderIP: String) -> [UInt8] {
            Packet.ethernet(
                destination: Packet.broadcastMAC, source: guestMAC, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: 2, senderMAC: senderMAC, senderIP: address(senderIP),
                    targetMAC: [0, 0, 0, 0, 0, 0], targetIP: address(senderIP)))
        }
        var otherMAC = syn
        otherMAC[11] = 0x99
        let spoofed = [
            otherMAC,
            claim(senderMAC: guestMAC, senderIP: "10.88.0.11"),
            claim(senderMAC: guestMAC, senderIP: "10.88.0.1"),
            claim(senderMAC: [0x02, 0, 0, 0, 0, 0x11], senderIP: "10.88.0.10"),
            guestFrame(
                to: github, Packet.protocolUDP, Packet.udp(sourcePort: 1, destinationPort: 2, payload: []),
                from: address("10.88.0.11")),
            gatewayMAC + guestMAC + [0x86, 0xdd] + [UInt8](repeating: 0x60, count: 60),
        ]

        let strict = inspector(TrafficPolicy(mode: .off))
        let first = strict.fromGuest(spoofed[0], now: now)
        #expect(first.events.first?.reason == "dropped a frame from another MAC address")
        for frame in spoofed {
            #expect(strict.fromGuest(frame, now: now).toNetwork.isEmpty)
        }
    }

    @Test func turningWatchingOffAndOnTakesEffectAtOnce() {
        let watcher = inspector(TrafficPolicy())
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let off = watcher.update(TrafficPolicy(mode: .off), now: now)
        #expect(off.events.first?.kind == .policy)
        #expect(off.events.last?.kind == .close)
        #expect(watcher.flows.isEmpty)

        let ack = guestTCP(to: github, flags: TCPSegment.ack, sequence: 1001)
        #expect(watcher.fromGuest(ack, now: now).toNetwork == [ack])
        #expect(watcher.flows.isEmpty)

        _ = watcher.update(TrafficPolicy(), now: now)
        let syn = watcher.fromGuest(guestTCP(to: "1.1.1.1", port: 22, flags: TCPSegment.syn), now: now)
        #expect(syn.toNetwork.count == 1)
        #expect(watcher.flows.count == 1)
    }

    @Test func uDPCanBeBlockedWithTheLists() throws {
        for mode in TrafficPolicy.Mode.allCases {
            let watcher = inspector(TrafficPolicy(mode: mode, allowed: ["github.com"], allowsUDP: false))
            let blocks = mode == .allowlist || mode == .blocklist

            let ntp = guestFrame(
                to: github, Packet.protocolUDP, Packet.udp(sourcePort: 5000, destinationPort: 123, payload: [1]))
            #expect(watcher.fromGuest(ntp, now: now).toNetwork.isEmpty == blocks, "\(mode)")

            let query = TrafficSamples.dnsQuery("github.com")
            let throughMac = guestFrame(
                to: "10.88.0.1", Packet.protocolUDP, Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)
            )
            #expect(watcher.fromGuest(throughMac, now: now).toNetwork.count == 1, "\(mode)")

            let incoming = networkFrame(
                from: "1.2.3.4", Packet.protocolUDP, Packet.udp(sourcePort: 5000, destinationPort: 6000, payload: [1]))
            #expect(watcher.fromNetwork(incoming, now: now).toGuest.isEmpty == blocks, "\(mode)")
        }
    }

    @Test func vMsCannotAnswerDHCP() {
        let offer = guestFrame(
            to: "255.255.255.255", Packet.protocolUDP,
            Packet.udp(sourcePort: 67, destinationPort: 68, payload: [UInt8](repeating: 0, count: 300)))

        for policy in [TrafficPolicy(mode: .off), TrafficPolicy(), TrafficPolicy(mode: .blocklist, allowsVMs: true)] {
            let output = inspector(policy).fromGuest(offer, now: now)
            #expect(output.toNetwork.isEmpty)
            #expect(output.events.first?.reason == "dropped a DHCP server reply")
        }
    }

    @Test func learnsItsAddressFromDHCP() {
        let watcher = TrafficInspector(
            guestMAC: guestMAC, guestIP: nil, subnet: subnet, gatewayMAC: gatewayMAC,
            serverMAC: serverMAC, policy: TrafficPolicy())
        let packet = guestFrame(
            to: github, Packet.protocolUDP, Packet.udp(sourcePort: 1, destinationPort: 2, payload: []))
        #expect(watcher.fromGuest(packet, now: now).toNetwork.isEmpty)

        var ack = [UInt8](repeating: 0, count: 240)
        ack[0] = 2
        ack.replaceSubrange(16..<20, with: Packet.bytes(guestIP))
        ack.replaceSubrange(28..<34, with: guestMAC)
        ack.replaceSubrange(236..<240, with: [99, 130, 83, 99])
        ack += [53, 1, 5, 255]
        func offer(from mac: [UInt8]) -> [UInt8] {
            Packet.ethernet(
                destination: Packet.broadcastMAC, source: mac, type: Packet.etherTypeIPv4,
                payload: Packet.ipv4(
                    source: address("10.88.0.2"), destination: 0xffff_ffff, protocol: Packet.protocolUDP,
                    payload: Packet.udp(sourcePort: 67, destinationPort: 68, payload: ack)))
        }

        #expect(watcher.fromNetwork(offer(from: [0x02, 0, 0, 0, 0, 0x66]), now: now).toGuest.count == 1)
        #expect(watcher.fromGuest(packet, now: now).toNetwork.isEmpty)
        #expect(watcher.fromNetwork(offer(from: serverMAC), now: now).toGuest.count == 1)
        #expect(watcher.fromGuest(packet, now: now).toNetwork.count == 1)

        let strict = TrafficInspector(
            guestMAC: guestMAC, guestIP: nil, subnet: subnet, gatewayMAC: gatewayMAC,
            serverMAC: serverMAC, policy: TrafficPolicy(mode: .allowlist))
        let spoofed = strict.fromNetwork(offer(from: [0x02, 0, 0, 0, 0, 0x66]), now: now)
        #expect(spoofed.toGuest.isEmpty)
        #expect(spoofed.events.first?.reason == "dropped a DHCP reply from another MAC address")
        #expect(strict.guestIP == nil)
    }

    /// A DNS-over-TCP connection that this Mac's resolver has accepted.
    private func connectedToTheMacsResolver(_ watcher: TrafficInspector) {
        _ = watcher.fromGuest(guestTCP(to: "10.88.0.1", port: 53, flags: TCPSegment.syn), now: now)
        let accepted = Packet.tcp(
            source: address("10.88.0.1"), destination: guestIP, sourcePort: 53, destinationPort: 50_000,
            sequence: 4999, acknowledgment: 1001, flags: TCPSegment.syn | TCPSegment.ack)
        _ = watcher.fromNetwork(networkFrame(from: "10.88.0.1", Packet.protocolTCP, accepted), now: now)
    }

    /// Guest data on that connection, `offset` bytes into the stream.
    private func toTheMacsResolver(_ bytes: [UInt8], at offset: Int = 0) -> [UInt8] {
        guestTCP(to: "10.88.0.1", port: 53, flags: TCPSegment.ack, sequence: 1001 + UInt32(offset), payload: bytes)
    }

    private func framed(_ query: [UInt8]) -> [UInt8] {
        [UInt8(query.count >> 8), UInt8(query.count & 0xff)] + query
    }

    private var allowList: TrafficPolicy { TrafficPolicy(mode: .allowlist, allowed: ["github.com"]) }

    private func connectedToGitHub(_ policy: TrafficPolicy? = nil) -> TrafficInspector {
        let watcher = inspector(policy ?? allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher)
        return watcher
    }

    private func serverAccepts(
        _ watcher: TrafficInspector, port: UInt16 = 443, acknowledgment: UInt32 = 1001, payload: [UInt8] = []
    ) -> TrafficInspector.Output {
        fromGitHub(
            watcher, port: port, flags: TCPSegment.syn | TCPSegment.ack, sequence: 4999, acknowledgment: acknowledgment,
            payload: payload)
    }

    private func fromGitHub(
        _ watcher: TrafficInspector, port: UInt16 = 443, flags: UInt8, sequence: UInt32 = 5000,
        acknowledgment: UInt32, payload: [UInt8] = []
    ) -> TrafficInspector.Output {
        let segment = Packet.tcp(
            source: address(github), destination: guestIP, sourcePort: port, destinationPort: 50_000,
            sequence: sequence, acknowledgment: acknowledgment, flags: flags, payload: payload)
        return watcher.fromNetwork(networkFrame(from: github, Packet.protocolTCP, segment), now: now)
    }

    private func hello(_ watcher: TrafficInspector, _ payload: [UInt8], sequence: UInt32 = 1001)
        -> TrafficInspector.Output
    {
        watcher.fromGuest(
            guestTCP(to: github, flags: TCPSegment.ack, sequence: sequence, acknowledgment: 5000, payload: payload),
            now: now)
    }

    @Test func dHCPPortsAreNotATunnel() {
        let out = guestFrame(
            to: "1.2.3.4", Packet.protocolUDP,
            Packet.udp(sourcePort: 68, destinationPort: 67, payload: [UInt8](repeating: 1, count: 300)))
        let strict = inspector(allowList)
        let blocked = strict.fromGuest(out, now: now)
        #expect(blocked.toNetwork.isEmpty)
        #expect(blocked.events.first?.verdict == .blocked)

        let back = networkFrame(
            from: "1.2.3.4", Packet.protocolUDP,
            Packet.udp(sourcePort: 67, destinationPort: 68, payload: [UInt8](repeating: 2, count: 300)))
        #expect(strict.fromNetwork(back, now: now).toGuest.isEmpty)

        let seen = inspector(TrafficPolicy()).fromGuest(out, now: now)
        #expect(seen.toNetwork.count == 1)
        #expect(seen.events.first?.address == "1.2.3.4")
    }

    @Test func onlyRealDHCPRequestsToTheServerPassUnchecked() {
        func request(to mac: [UInt8], payload: [UInt8]) -> [UInt8] {
            Packet.ethernet(
                destination: mac, source: guestMAC, type: Packet.etherTypeIPv4,
                payload: Packet.ipv4(
                    source: 0, destination: 0xffff_ffff, protocol: Packet.protocolUDP,
                    payload: Packet.udp(sourcePort: 68, destinationPort: 67, payload: payload)))
        }
        var discover = [UInt8](repeating: 0, count: 240)
        discover[0] = 1
        discover[1] = 1
        discover[2] = 6
        discover.replaceSubrange(28..<34, with: guestMAC)
        discover.replaceSubrange(236..<240, with: [99, 130, 83, 99])
        discover += [53, 1, 1, 255]
        let isolated = inspector(TrafficPolicy(isolated: true), guestIP: 0)
        let otherVM: [UInt8] = [0x02, 0, 0, 0, 0, 0x20]

        #expect(
            isolated.fromGuest(request(to: Packet.broadcastMAC, payload: discover), now: now).toNetwork
                == [request(to: serverMAC, payload: discover)])
        #expect(isolated.fromGuest(request(to: otherVM, payload: discover), now: now).toNetwork.isEmpty)

        var smuggled = [UInt8](repeating: 7, count: 1400)
        smuggled.replaceSubrange(28..<34, with: guestMAC)
        #expect(isolated.fromGuest(request(to: Packet.broadcastMAC, payload: smuggled), now: now).toNetwork.isEmpty)

        #expect(
            inspector(TrafficPolicy(), guestIP: 0).fromGuest(
                request(to: Packet.broadcastMAC, payload: discover), now: now
            ).toNetwork
                == [request(to: Packet.broadcastMAC, payload: discover)])
    }

    @Test func strictVMsSendDHCPRequestsOnlyToTheServer() {
        func request(to mac: [UInt8]) -> [UInt8] {
            var discover = [UInt8](repeating: 0, count: 240)
            discover[0] = 1
            discover[1] = 1
            discover[2] = 6
            discover.replaceSubrange(28..<34, with: guestMAC)
            discover.replaceSubrange(236..<240, with: [99, 130, 83, 99])
            discover += [53, 1, 1, 255]
            return Packet.ethernet(
                destination: mac, source: guestMAC, type: Packet.etherTypeIPv4,
                payload: Packet.ipv4(
                    source: 0, destination: 0xffff_ffff, protocol: Packet.protocolUDP,
                    payload: Packet.udp(sourcePort: 68, destinationPort: 67, payload: discover)))
        }

        let isolated = inspector(TrafficPolicy(isolated: true), guestIP: 0)
        #expect(isolated.start(now: now).toNetwork.isEmpty)
        #expect(isolated.fromGuest(request(to: Packet.broadcastMAC), now: now).toNetwork == [request(to: serverMAC)])
        #expect(isolated.fromGuest(request(to: serverMAC), now: now).toNetwork == [request(to: serverMAC)])

        let strict = inspector(TrafficPolicy(mode: .allowlist), guestIP: 0)
        #expect(strict.start(now: now).toNetwork.isEmpty)
        #expect(strict.fromGuest(request(to: Packet.broadcastMAC), now: now).toNetwork == [request(to: serverMAC)])

        let shared = inspector(TrafficPolicy(mode: .allowlist, allowsVMs: true), guestIP: 0)
        #expect(shared.start(now: now).toNetwork.isEmpty)
        #expect(
            shared.fromGuest(request(to: Packet.broadcastMAC), now: now).toNetwork == [request(to: Packet.broadcastMAC)]
        )

        let monitor = inspector(TrafficPolicy(), guestIP: 0)
        #expect(monitor.start(now: now).toNetwork.isEmpty)
        #expect(monitor.update(TrafficPolicy(isolated: true), now: now).toNetwork.isEmpty)
        #expect(monitor.fromGuest(request(to: Packet.broadcastMAC), now: now).toNetwork == [request(to: serverMAC)])
    }

    @Test func laterFragmentsReachTheGuestOnlyWhenNothingIsEnforced() {
        var header = Packet.ipv4(
            source: address(github), destination: guestIP, protocol: Packet.protocolUDP,
            payload: [UInt8](repeating: 3, count: 64))
        header[6] = 0x00
        header[7] = 0x10
        let fragment = Packet.ethernet(
            destination: guestMAC, source: gatewayMAC, type: Packet.etherTypeIPv4, payload: header)

        #expect(inspector(TrafficPolicy()).fromNetwork(fragment, now: now).toGuest.count == 1)
        #expect(inspector(TrafficPolicy(isolated: true)).fromNetwork(fragment, now: now).toGuest.isEmpty)
        #expect(inspector(allowList).fromNetwork(fragment, now: now).toGuest.isEmpty)
    }

    @Test func aFakeResetDoesNotShieldAConnection() {
        let watcher = inspector(TrafficPolicy())
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.rst, sequence: 99_999), now: now)
        _ = watcher.update(TrafficPolicy(isolated: true), now: now)

        let next = watcher.fromGuest(
            guestTCP(to: github, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 7000), now: now)

        #expect(next.toNetwork.isEmpty)
        #expect(reset(in: next.toGuest) != nil)
    }

    @Test func aNewConnectionOnAClosedPortIsCheckedAgain() {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher)

        let allowed = watcher.fromGuest(
            guestTCP(
                to: github, flags: TCPSegment.ack | 0x08, sequence: 1001,
                payload: TrafficSamples.clientHello(serverName: "github.com")), now: now)
        #expect(allowed.toNetwork.count == 1)
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.rst, sequence: 2000), now: now)

        let reopened = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 5000), now: now)
        #expect(reopened.toNetwork.count == 1)
        #expect(reopened.events.map(\.kind) == [.close])
        _ = serverAccepts(watcher, acknowledgment: 5001)

        let foreign = watcher.fromGuest(
            guestTCP(
                to: github, flags: TCPSegment.ack | 0x08, sequence: 5001,
                payload: TrafficSamples.clientHello(serverName: "evil.example")), now: now)
        #expect(reset(in: foreign.toGuest) != nil)
        #expect(foreign.events.first?.host == "evil.example")
        #expect(foreign.events.first?.verdict == .blocked)
    }

    @Test func aSYNWithAnotherSequenceStartsANewCheckedConnection() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x8000_0000), now: now)

        let second = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x1000), now: now)
        _ = serverAccepts(watcher, acknowledgment: 0x1001)
        let foreign = hello(watcher, TrafficSamples.clientHello(serverName: "other.example"), sequence: 0x1001)

        #expect(second.toNetwork.count == 1)
        #expect(second.events.last?.reason == "replaced by a new connection")
        #expect(reset(in: foreign.toGuest) != nil)
        #expect(foreign.toNetwork.count == 1)
        #expect(reset(in: foreign.toNetwork) != nil)
        #expect(foreign.events.contains { $0.reason == "other.example is not allowed" })
    }

    @Test func aResentSYNKeepsItsConnection() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let resent = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher)
        let foreign = hello(watcher, TrafficSamples.clientHello(serverName: "other.example"))

        #expect(resent.toNetwork.count == 1)
        #expect(resent.events.isEmpty)
        #expect(reset(in: foreign.toGuest) != nil)
        #expect(foreign.events.filter { $0.kind == .connect }.count == 1)
    }

    @Test func aNewSYNAfterAnAllowedConnectionIsCheckedAgain() {
        let watcher = connectedToGitHub()
        _ = hello(watcher, TrafficSamples.clientHello(serverName: "github.com"))

        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x4000_0000), now: now)
        _ = serverAccepts(watcher, acknowledgment: 0x4000_0001)
        let foreign = hello(watcher, TrafficSamples.clientHello(serverName: "other.example"), sequence: 0x4000_0001)

        #expect(reset(in: foreign.toGuest) != nil)
        #expect(foreign.events.contains { $0.reason == "other.example is not allowed" })
    }

    @Test func aRetryWithAHigherSequenceIsForwarded() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let retry = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 9000), now: now)
        _ = serverAccepts(watcher, acknowledgment: 9001)
        let allowed = hello(watcher, TrafficSamples.clientHello(serverName: "github.com"), sequence: 9001)

        #expect(retry.toNetwork.count == 1)
        #expect(allowed.toNetwork.count == 1)
        #expect(reset(in: allowed.toNetwork) == nil)
    }

    @Test func aNewSYNCannotContinueAConnectionTheServerStillHolds() {
        let watcher = connectedToGitHub()
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x8000_0000), now: now)

        let challenge = fromGitHub(watcher, flags: TCPSegment.ack, acknowledgment: 1001)
        let foreign = hello(watcher, TrafficSamples.clientHello(serverName: "other.example"))
        let serverHello = fromGitHub(
            watcher, flags: TCPSegment.ack, acknowledgment: 1001, payload: [0x16, 3, 3, 0, 1, 2])

        #expect(challenge.toGuest.count == 1)
        #expect(foreign.toNetwork.isEmpty)
        #expect(foreign.events.first?.reason == "sent before the server answered")
        #expect(serverHello.toGuest.isEmpty)
    }

    @Test func onlyTheAnswerToTheGuestsOwnSYNReachesIt() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x2000), now: now)
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, sequence: 0x1000), now: now)

        let staleAnswer = serverAccepts(watcher, acknowledgment: 0x2001)
        let foreign = hello(watcher, TrafficSamples.clientHello(serverName: "other.example"), sequence: 0x2001)
        let answer = serverAccepts(watcher, acknowledgment: 0x1001)
        let allowed = hello(watcher, TrafficSamples.clientHello(serverName: "github.com"), sequence: 0x1001)

        #expect(staleAnswer.toGuest.isEmpty)
        #expect(foreign.toNetwork.isEmpty)
        #expect(answer.toGuest.count == 1)
        #expect(allowed.toNetwork.count == 1)
    }

    @Test func untilTheServerAnswersTheGuestCanOnlyResendItsSYN() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let early = hello(watcher, TrafficSamples.clientHello(serverName: "github.com"))
        let earlyAck = watcher.fromGuest(
            guestTCP(to: github, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 5000), now: now)
        let resent = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        #expect(early.toNetwork.isEmpty)
        #expect(early.events.map(\.verdict) == [.blocked])
        #expect(earlyAck.toNetwork.isEmpty)
        #expect(earlyAck.events.isEmpty)
        #expect(resent.toNetwork.count == 1)
    }

    @Test func dataInTheSYNIsCheckedAndItsAnswerAccepted() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        let clientHello = TrafficSamples.clientHello(serverName: "github.com")

        let opening = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn, payload: clientHello), now: now)
        let answer = serverAccepts(watcher, acknowledgment: 1001 + UInt32(clientHello.count))
        let resent = hello(watcher, clientHello)

        #expect(opening.toNetwork.count == 1)
        #expect(opening.events.first?.host == "github.com")
        #expect(answer.toGuest.count == 1)
        #expect(resent.toNetwork.count == 1)
        #expect(resent.events.isEmpty)
    }

    @Test func aSYNACKCarryingDataAcceptsTheConnection() {
        let watcher = inspector(allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now)

        let answer = serverAccepts(watcher, payload: bytes("220 ready\r\n"))
        let next = watcher.fromGuest(
            guestTCP(to: github, flags: TCPSegment.ack, sequence: 1001, acknowledgment: 5011), now: now)

        #expect(answer.toGuest.count == 1)
        #expect(next.toNetwork.count == 1)
    }

    @Test func outOfOrderDataWaitsUntilTheHostIsKnown() {
        let watcher = connectedToGitHub()
        let foreign = TrafficSamples.clientHello(serverName: "evil.example")

        let early = hello(watcher, Array(foreign.dropFirst()), sequence: 1002)
        #expect(early.toNetwork.isEmpty)
        #expect(early.events.isEmpty)

        #expect(hello(watcher, [foreign[0]]).toNetwork.count == 1)

        let rest = hello(watcher, Array(foreign.dropFirst()), sequence: 1002)
        #expect(rest.toNetwork.count == 1)
        #expect(reset(in: rest.toNetwork) != nil)
        #expect(rest.events.first?.host == "evil.example")
    }

    @Test func resendingDifferentDataIsBlocked() {
        let watcher = connectedToGitHub()
        let allowed = TrafficSamples.clientHello(serverName: "github.com")

        #expect(hello(watcher, allowed).toNetwork.count == 1)
        #expect(hello(watcher, allowed).toNetwork.count == 1)

        let decoy = hello(watcher, TrafficSamples.clientHello(serverName: "evil.example"))
        #expect(decoy.events.first?.reason == "resent different data")
        #expect(reset(in: decoy.toGuest) != nil)
    }

    @Test func allowListNeedsAReadableHostName() {
        #expect(
            hello(connectedToGitHub(), TrafficSamples.clientHello(serverName: nil)).events.first?.reason
                == "TLS without a host name")

        let split = TrafficSamples.splitRecords(TrafficSamples.clientHello(serverName: "evil.example"), at: 10)
        #expect(hello(connectedToGitHub(), split).events.first?.host == "evil.example")

        let early = connectedToGitHub().fromGuest(
            guestTCP(
                to: github, flags: TCPSegment.syn,
                payload: TrafficSamples.clientHello(serverName: "evil.example")), now: now)
        #expect(early.events.last?.verdict == .blocked)
        #expect(early.toNetwork.count == 1)
    }

    @Test func allowListRefusesConnectionsItNeverSawOpen() {
        let midway = guestTCP(
            to: github, flags: TCPSegment.ack, sequence: 5000, acknowledgment: 9000, payload: [1, 2, 3])

        let refused = inspector(allowList).fromGuest(midway, now: now)

        #expect(refused.toNetwork.isEmpty)
        #expect(reset(in: refused.toGuest)?.sequence == 9000)
        #expect(inspector(TrafficPolicy()).fromGuest(midway, now: now).toNetwork.count == 1)
    }

    @Test func dNSOverTCPAndUnusualICMPAreChecked() {
        let strict = inspector(allowList)
        #expect(
            strict.fromGuest(guestTCP(to: "10.88.0.1", port: 53, flags: TCPSegment.syn), now: now).events.first?.reason
                == "DNS over TCP is blocked")

        let timestamp = guestFrame(
            to: github, Packet.protocolICMP, [13, 0, 0, 0, 0, 1, 0, 1] + [UInt8](repeating: 0x41, count: 64))
        #expect(strict.fromGuest(timestamp, now: now).toNetwork.isEmpty)
        #expect(inspector(TrafficPolicy()).fromGuest(timestamp, now: now).toNetwork.count == 1)

        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        connectedToTheMacsResolver(lenient)
        let query = TrafficSamples.dnsQuery("evil.example")

        let asked = lenient.fromGuest(toTheMacsResolver(framed(query)), now: now)

        #expect(asked.events.first?.kind == .dns)
        #expect(asked.events.first?.verdict == .blocked)
        #expect(reset(in: asked.toNetwork) != nil)
        #expect(asked.toNetwork.count == 1)
    }

    @Test func blockListKeepsDNSOnThisMacAndRefusesOtherPayloadOnPort53() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist))
        lenient.hostAddresses = [address("192.168.1.5")]
        let query = TrafficSamples.dnsQuery("github.com")

        let elsewhere = lenient.fromGuest(
            guestFrame(
                to: "8.8.8.8", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)
        #expect(elsewhere.toNetwork.isEmpty)
        #expect(elsewhere.toGuest.count == 1)
        #expect(elsewhere.events.first?.reason == "DNS only through this Mac")

        let viaHost = lenient.fromGuest(guestTCP(to: "192.168.1.5", port: 53, flags: TCPSegment.syn), now: now)
        #expect(viaHost.toNetwork.isEmpty)
        #expect(viaHost.events.first?.reason == "DNS only through this Mac")

        #expect(
            lenient.fromGuest(guestTCP(to: "10.88.0.1", port: 53, flags: TCPSegment.syn), now: now).toNetwork.count == 1
        )
        let accepted = Packet.tcp(
            source: address("10.88.0.1"), destination: guestIP, sourcePort: 53, destinationPort: 50_000,
            sequence: 4999, acknowledgment: 1001, flags: TCPSegment.syn | TCPSegment.ack)
        _ = lenient.fromNetwork(networkFrame(from: "10.88.0.1", Packet.protocolTCP, accepted), now: now)

        let asked = lenient.fromGuest(toTheMacsResolver(framed(query)), now: now)
        #expect(asked.toNetwork.count == 1)
        #expect(reset(in: asked.toNetwork) == nil)
        #expect(asked.events.first?.verdict == .allowed)

        let smuggled = lenient.fromGuest(
            guestTCP(
                to: "10.88.0.1", port: 53, flags: TCPSegment.ack, sequence: 1001 + UInt32(query.count) + 2,
                payload: Array("GET / HTTP/1.1\r\n\r\n".utf8)), now: now)
        #expect(reset(in: smuggled.toNetwork) != nil)
        #expect(smuggled.toNetwork.count == 1)
        #expect(smuggled.events.first?.reason == "not a DNS query")

        let watcher = inspector(TrafficPolicy())
        _ = watcher.fromGuest(guestTCP(to: "10.88.0.1", port: 53, flags: TCPSegment.syn), now: now)
        let seen = watcher.fromGuest(
            guestTCP(
                to: "10.88.0.1", port: 53, flags: TCPSegment.ack, sequence: 1001,
                payload: Array("GET / HTTP/1.1\r\n\r\n".utf8)), now: now)
        #expect(seen.toNetwork.count == 1)
        #expect(reset(in: seen.toNetwork) == nil)
    }

    @Test func aDNSQuerySplitAcrossSegmentsIsCheckedWhole() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        connectedToTheMacsResolver(lenient)
        let stream = framed(TrafficSamples.dnsQuery("evil.example"))

        let first = lenient.fromGuest(toTheMacsResolver(Array(stream[..<10])), now: now)
        let rest = lenient.fromGuest(toTheMacsResolver(Array(stream[10...]), at: 10), now: now)

        #expect(first.toNetwork.count == 1 && reset(in: first.toNetwork) == nil)
        #expect(rest.toNetwork.count == 1 && reset(in: rest.toNetwork) != nil)
        #expect(rest.events.first?.verdict == .blocked)
    }

    @Test func anAllowedSplitQueryPassesAndIsLogged() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        connectedToTheMacsResolver(lenient)
        let stream = framed(TrafficSamples.dnsQuery("github.com"))

        let first = lenient.fromGuest(toTheMacsResolver(Array(stream[..<10])), now: now)
        let rest = lenient.fromGuest(toTheMacsResolver(Array(stream[10...]), at: 10), now: now)

        #expect(first.toNetwork.count == 1 && rest.toNetwork.count == 1)
        #expect(rest.events.first?.verdict == .allowed && rest.events.first?.reason == "over TCP")
    }

    @Test func aResentSegmentWithOtherBytesIsRefused() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        connectedToTheMacsResolver(lenient)
        let allowed = framed(TrafficSamples.dnsQuery("good.example"))
        let blocked = framed(TrafficSamples.dnsQuery("evil.example"))

        _ = lenient.fromGuest(toTheMacsResolver(Array(allowed[..<20])), now: now)
        let resent = lenient.fromGuest(toTheMacsResolver(blocked), now: now)

        #expect(reset(in: resent.toNetwork) != nil)
        #expect(resent.events.contains { $0.reason == "resent different data" })
    }

    @Test func aBlockedSecondQueryInTheSameSegmentResetsTheConnection() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))
        connectedToTheMacsResolver(lenient)
        let both = framed(TrafficSamples.dnsQuery("github.com")) + framed(TrafficSamples.dnsQuery("evil.example"))

        let output = lenient.fromGuest(toTheMacsResolver(both), now: now)

        #expect(output.toNetwork.count == 1 && reset(in: output.toNetwork) != nil)
        #expect(output.events.map(\.verdict) == [.allowed, .blocked, .blocked])
    }

    @Test(arguments: [[0, 0] + [UInt8](repeating: 0, count: 12), [0x10, 0x01]])
    func aDNSLengthOutsideTheLimitsIsRefusedAtOnce(stream: [UInt8]) {
        let lenient = inspector(TrafficPolicy(mode: .blocklist))
        connectedToTheMacsResolver(lenient)

        let output = lenient.fromGuest(toTheMacsResolver(stream), now: now)

        #expect(reset(in: output.toNetwork) != nil)
        #expect(output.events.first?.reason == "not a DNS query")
    }

    /// Rules switched on while a DNS-over-TCP connection is open: its stream was never read from the start.
    @Test func dNSOverTCPSeenMidStreamIsRefusedOnceRulesApply() {
        let query = framed(TrafficSamples.dnsQuery("github.com"))
        let watcher = inspector(TrafficPolicy())

        let passed = watcher.fromGuest(toTheMacsResolver(query), now: now)
        _ = watcher.update(TrafficPolicy(mode: .blocklist), now: now)
        let refused = watcher.fromGuest(toTheMacsResolver(query, at: query.count), now: now)

        #expect(passed.toNetwork.count == 1 && reset(in: passed.toNetwork) == nil)
        #expect(reset(in: refused.toNetwork) != nil)
        #expect(refused.events.contains { $0.reason == "DNS over TCP seen mid-stream" })
    }

    @Test func unreadableDNSQueriesToTheMacAreBlockedUnlessOnlyWatched() {
        let github = TrafficSamples.dnsQuery("github.com")
        let question = Array(github[12...])
        let evilQuestion = Array(TrafficSamples.dnsQuery("evil.example")[12...])
        func header(questions: UInt8) -> [UInt8] {
            var bytes = Array(github[..<12])
            bytes[5] = questions
            return bytes
        }
        var broken = github
        broken[12] = 63
        let queries = [
            header(questions: 0), header(questions: 2) + question + evilQuestion,
            header(questions: 9) + Array([[UInt8]](repeating: question, count: 9).joined()), broken,
        ]

        for query in queries {
            let frame = guestFrame(
                to: "10.88.0.1", Packet.protocolUDP, Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)
            )
            let guarded = inspector(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))

            let blocked = guarded.fromGuest(frame, now: now)
            let passed = inspector(TrafficPolicy()).fromGuest(frame, now: now)

            #expect(blocked.toNetwork.isEmpty)
            #expect(blocked.events.map(\.reason) == ["not a DNS query"])
            #expect(passed.toNetwork.count == 1)
        }
    }

    @Test func aNeighbourCannotClaimTheVMsOwnAddress() {
        let neighbour: [UInt8] = [0x02, 0, 0, 0, 0, 0x22]
        let claim = Packet.ethernet(
            destination: Packet.broadcastMAC, source: neighbour, type: Packet.etherTypeARP,
            payload: Packet.arp(
                operation: 2, senderMAC: neighbour, senderIP: guestIP, targetMAC: guestMAC, targetIP: guestIP))
        let shared = inspector(TrafficPolicy(mode: .blocklist, allowsVMs: true))
        let dropped = shared.fromNetwork(claim, now: now)
        #expect(dropped.toGuest.isEmpty)
        #expect(
            dropped.events.first?.reason
                == "dropped an ARP claim for the VM's own address 10.88.0.10 from another MAC address")

        let probe = Packet.ethernet(
            destination: Packet.broadcastMAC, source: neighbour, type: Packet.etherTypeARP,
            payload: Packet.arp(
                operation: 1, senderMAC: neighbour, senderIP: 0, targetMAC: [0, 0, 0, 0, 0, 0], targetIP: guestIP))
        #expect(shared.fromNetwork(probe, now: now).toGuest.count == 1)

        #expect(inspector(TrafficPolicy()).fromNetwork(claim, now: now).toGuest.count == 1)
    }

    @Test func onlyLookupsThroughTheMacOpenAnAllowList() {
        let watcher = inspector(TrafficPolicy())
        let query = TrafficSamples.dnsQuery("github.com")
        _ = watcher.fromGuest(
            guestFrame(
                to: "8.8.8.8", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)
        let answer = TrafficSamples.dnsAnswer(to: query, addresses: ["6.6.6.6"])
        _ = watcher.fromNetwork(
            networkFrame(
                from: "8.8.8.8", Packet.protocolUDP,
                Packet.udp(sourcePort: 53, destinationPort: 40_000, payload: answer)), now: now)

        _ = watcher.update(allowList, now: now)
        let output = watcher.fromGuest(guestTCP(to: "6.6.6.6", flags: TCPSegment.syn), now: now)

        #expect(output.toNetwork.isEmpty)
        #expect(output.events.first?.reason == "github.com was not looked up through this Mac")
    }

    @Test func theLocalNetworkIsBlockedUnlessAllowed() {
        func syn(_ watcher: TrafficInspector, to destination: String) -> TrafficInspector.Output {
            watcher.fromGuest(guestTCP(to: destination, port: 445, flags: TCPSegment.syn), now: now)
        }

        let strict = inspector(TrafficPolicy(mode: .blocklist))
        #expect(syn(strict, to: "192.168.1.20").events.first?.reason == "the local network is blocked")
        #expect(syn(strict, to: "169.254.1.1").toNetwork.isEmpty)
        #expect(syn(strict, to: "8.8.4.4").toNetwork.count == 1)

        let nas = inspector(TrafficPolicy(mode: .allowlist, allowed: ["192.168.1.20"]))
        #expect(syn(nas, to: "192.168.1.20").toNetwork.count == 1)
        #expect(syn(nas, to: "192.168.1.21").events.first?.reason == "the local network is blocked")

        let open = inspector(TrafficPolicy(mode: .blocklist, blocked: ["10.1.0.0/16"], allowsLocalNetwork: true))
        #expect(syn(open, to: "172.16.4.4").toNetwork.count == 1)
        #expect(syn(open, to: "10.1.2.3").events.first?.reason == "blocked by 10.1.0.0/16")

        #expect(syn(inspector(TrafficPolicy(mode: .monitor)), to: "192.168.1.20").toNetwork.count == 1)
    }

    @Test func theMacsOtherAddressesAndUnexpectedIncomingTraffic() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist))
        lenient.hostAddresses = [address("192.168.1.5")]
        #expect(
            lenient.fromGuest(guestTCP(to: "192.168.1.5", port: 8080, flags: TCPSegment.syn), now: now).events.first?
                .reason == "this Mac is blocked")

        let inbound = Packet.tcp(
            source: address("1.2.3.4"), destination: guestIP, sourcePort: 443, destinationPort: 50_000,
            sequence: 1, acknowledgment: 0, flags: TCPSegment.syn)
        let stray = lenient.fromNetwork(networkFrame(from: "1.2.3.4", Packet.protocolTCP, inbound), now: now)
        #expect(stray.toGuest.isEmpty)
        #expect(stray.events.first?.reason == "unexpected incoming traffic")
    }

    @Test func floodsAreSummarized() {
        let lenient = inspector(TrafficPolicy(mode: .blocklist, blocked: ["9.0.0.0/8"]))
        var events: [TrafficEvent] = []
        for index in 0..<1000 {
            events +=
                lenient.fromGuest(guestTCP(to: "9.0.\(index / 256).\(index % 256)", flags: TCPSegment.syn), now: now)
                .events
        }

        #expect(events.count == TrafficInspector.maximumEventsPerSecond)

        let later = lenient.expire(now: now.addingTimeInterval(2))
        #expect(later.events.first?.kind == .notice)
        #expect(later.events.first?.reason?.hasPrefix("700 more events") == true)
    }

    @Test func aRPIsRebuiltAndKeptAwayFromOtherVMs() {
        let strict = inspector(TrafficPolicy(mode: .allowlist, allowsVMs: false))
        func arp(_ target: String) -> [UInt8] {
            Packet.ethernet(
                destination: Packet.broadcastMAC, source: guestMAC, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: 1, senderMAC: guestMAC, senderIP: guestIP,
                    targetMAC: [0, 0, 0, 0, 0, 0], targetIP: address(target)) + [UInt8](repeating: 0x55, count: 18))
        }

        #expect(strict.fromGuest(arp("10.88.0.11"), now: now).toNetwork.isEmpty)
        #expect(strict.fromGuest(arp("10.88.0.1"), now: now).toNetwork.first?.count == 42)
    }

    @Test func anICMPErrorFromAnotherVMReachesTheGuestOnlyWhenVMsMayTalk() {
        let unreachable: [UInt8] = [3, 1, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 28)
        func error(from source: String, mac: [UInt8]) -> [UInt8] {
            Packet.ethernet(
                destination: guestMAC, source: mac, type: Packet.etherTypeIPv4,
                payload: Packet.ipv4(
                    source: address(source), destination: guestIP, protocol: Packet.protocolICMP,
                    payload: unreachable))
        }
        let fromVM = error(from: "10.88.0.11", mac: [0x02, 0, 0, 0, 0, 0x22])
        let fromRouter = error(from: "203.0.113.1", mac: gatewayMAC)
        let vmsAllowed = TrafficPolicy(mode: .allowlist, allowsVMs: true)

        #expect(inspector(allowList).fromNetwork(fromVM, now: now).toGuest.isEmpty)
        #expect(inspector(vmsAllowed).fromNetwork(fromVM, now: now).toGuest.count == 1)
        #expect(inspector(allowList).fromNetwork(fromRouter, now: now).toGuest.count == 1)
    }

    @Test func aUDPHeaderThatLiesIsDroppedNotPassedAsPlainIP() {
        var datagram = Packet.udp(sourcePort: 40_000, destinationPort: 443, payload: [1, 2, 3, 4])
        datagram[5] = 200
        let frame = guestFrame(to: github, Packet.protocolUDP, datagram)
        let allowList = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        _ = resolve(allowList, "github.com", to: [github])

        let enforced = allowList.fromGuest(frame, now: now)
        let watched = inspector(TrafficPolicy()).fromGuest(frame, now: now)

        #expect(enforced.toNetwork.isEmpty)
        #expect(watched.toNetwork.count == 1)
    }

    @Test func anAllowRuleInsideHangarsNetworkOpensJustThatVMBothWays() {
        let neighbour: [UInt8] = [0x02, 0, 0, 0, 0, 0x22]
        let pair = inspector(TrafficPolicy(mode: .allowlist, allowed: ["10.88.0.11"]))
        let localNetwork = inspector(TrafficPolicy(mode: .allowlist, allowed: ["10.0.0.0/8"]))
        func arp(to target: String) -> [UInt8] {
            Packet.ethernet(
                destination: Packet.broadcastMAC, source: guestMAC, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: 1, senderMAC: guestMAC, senderIP: guestIP, targetMAC: [0, 0, 0, 0, 0, 0],
                    targetIP: address(target)))
        }
        func claim(from sender: String) -> [UInt8] {
            Packet.ethernet(
                destination: guestMAC, source: neighbour, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: 2, senderMAC: neighbour, senderIP: address(sender), targetMAC: guestMAC,
                    targetIP: guestIP))
        }
        let inbound = Packet.tcp(
            source: address("10.88.0.11"), destination: guestIP, sourcePort: 60_000, destinationPort: 22,
            sequence: 1, acknowledgment: 0, flags: TCPSegment.syn)

        let toNamed = pair.fromGuest(guestTCP(to: "10.88.0.11", port: 22, flags: TCPSegment.syn), now: now)
        let toOther = pair.fromGuest(guestTCP(to: "10.88.0.12", port: 22, flags: TCPSegment.syn), now: now)
        let fromNamed = pair.fromNetwork(networkFrame(from: "10.88.0.11", Packet.protocolTCP, inbound), now: now)
        let throughWideRule = localNetwork.fromGuest(
            guestTCP(to: "10.88.0.11", port: 22, flags: TCPSegment.syn), now: now)

        #expect(toNamed.toNetwork.count == 1)
        #expect(toOther.events.first?.reason == "other VMs are blocked")
        #expect(fromNamed.toGuest.count == 1)
        #expect(throughWideRule.events.first?.reason == "other VMs are blocked")
        #expect(pair.fromGuest(arp(to: "10.88.0.11"), now: now).toNetwork.count == 1)
        #expect(pair.fromGuest(arp(to: "10.88.0.12"), now: now).toNetwork.isEmpty)
        #expect(pair.fromNetwork(claim(from: "10.88.0.11"), now: now).toGuest.count == 1)
        #expect(pair.fromNetwork(claim(from: "10.88.0.12"), now: now).toGuest.isEmpty)
    }

    @Test func theMacsAddressesArePinnedByTheNetwork() {
        let attacker: [UInt8] = [0x02, 0, 0, 0, 0, 0x66]
        func reply(from mac: [UInt8], claiming ip: String) -> [UInt8] {
            Packet.ethernet(
                destination: guestMAC, source: mac, type: Packet.etherTypeARP,
                payload: Packet.arp(
                    operation: 2, senderMAC: mac, senderIP: address(ip), targetMAC: guestMAC, targetIP: guestIP))
        }
        let strict = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"], allowsVMs: true))

        let spoofed = strict.fromNetwork(reply(from: attacker, claiming: "10.88.0.1"), now: now)
        #expect(spoofed.toGuest.isEmpty)
        #expect(spoofed.events.first?.reason == "dropped an ARP claim for 10.88.0.1 from another MAC address")
        #expect(strict.fromNetwork(reply(from: attacker, claiming: "10.88.0.2"), now: now).toGuest.isEmpty)
        #expect(strict.hostMACs[address("10.88.0.1")] == gatewayMAC)
        #expect(strict.fromNetwork(reply(from: gatewayMAC, claiming: "10.88.0.1"), now: now).toGuest.count == 1)
        #expect(strict.fromNetwork(reply(from: attacker, claiming: "10.88.0.11"), now: now).toGuest.count == 1)

        _ = resolve(strict, "github.com", to: [github])
        let syn = Packet.tcp(
            source: guestIP, destination: address(github), sourcePort: 50_000, destinationPort: 443,
            sequence: 1000, acknowledgment: 0, flags: TCPSegment.syn)
        let viaAttacker = Packet.ethernet(
            destination: attacker, source: guestMAC, type: Packet.etherTypeIPv4,
            payload: Packet.ipv4(
                source: guestIP, destination: address(github), protocol: Packet.protocolTCP, payload: syn))
        let intercepted = strict.fromGuest(viaAttacker, now: now.addingTimeInterval(20))
        #expect(intercepted.toNetwork.isEmpty)
        #expect(intercepted.events.first?.reason == "dropped packets for \(github) sent to another MAC address")
        #expect(strict.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now).toNetwork.count == 1)

        let loose = inspector(TrafficPolicy())
        _ = loose.fromNetwork(reply(from: gatewayMAC, claiming: "10.88.0.1"), now: now)
        #expect(loose.fromNetwork(reply(from: attacker, claiming: "10.88.0.1"), now: now).toGuest.count == 1)
        #expect(loose.fromGuest(viaAttacker, now: now).toNetwork.count == 1)
    }

    @Test func aliasesOfAllowedNamesCanBeLookedUp() {
        let strict = inspector(TrafficPolicy(mode: .allowlist, allowed: ["deb.debian.org"]))
        let query = TrafficSamples.dnsQuery("deb.debian.org")
        _ = strict.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 40_000, destinationPort: 53, payload: query)), now: now)
        let answer = TrafficSamples.dnsAnswer(to: query, addresses: [], alias: "debian.map.fastly.net")
        _ = strict.fromNetwork(
            networkFrame(
                from: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(sourcePort: 53, destinationPort: 40_000, payload: answer)), now: now)

        let follow = resolve(strict, "debian.map.fastly.net", to: ["151.101.2.132"])
        #expect(follow.toGuest.count == 1)

        let connect = strict.fromGuest(guestTCP(to: "151.101.2.132", port: 80, flags: TCPSegment.syn), now: now)
        #expect(connect.toNetwork.count == 1)

        let other = strict.fromGuest(
            guestFrame(
                to: "10.88.0.1", Packet.protocolUDP,
                Packet.udp(
                    sourcePort: 40_001, destinationPort: 53, payload: TrafficSamples.dnsQuery("other.fastly.net"))),
            now: now)
        #expect(other.toNetwork.isEmpty)
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func web(_ policy: TrafficPolicy? = nil) -> TrafficInspector {
        let watcher = inspector(policy ?? allowList)
        _ = resolve(watcher, "github.com", to: [github])
        _ = watcher.fromGuest(guestTCP(to: github, port: 80, flags: TCPSegment.syn), now: now)
        _ = serverAccepts(watcher, port: 80)
        return watcher
    }

    private func send(_ watcher: TrafficInspector, _ payload: [UInt8], at sequence: UInt32) -> TrafficInspector.Output {
        watcher.fromGuest(
            guestTCP(
                to: github, port: 80, flags: TCPSegment.ack, sequence: sequence, acknowledgment: 5000, payload: payload),
            now: now)
    }

    private func ack(_ watcher: TrafficInspector, _ acknowledgment: UInt32) {
        let segment = Packet.tcp(
            source: address(github), destination: guestIP, sourcePort: 80, destinationPort: 50_000,
            sequence: 5000, acknowledgment: acknowledgment, flags: TCPSegment.ack)
        _ = watcher.fromNetwork(networkFrame(from: github, Packet.protocolTCP, segment), now: now)
    }

    private let good = "GET / HTTP/1.1\r\nHost: github.com\r\n\r\n"
    private let evil = "GET /x HTTP/1.1\r\nHost: evil.example\r\n\r\n"

    @Test func everyRequestOnAKeptAliveConnectionIsChecked() {
        let watcher = web()
        let first = send(watcher, bytes(good), at: 1001)
        #expect(first.toNetwork.count == 1)
        #expect(first.events.map(\.kind) == [.connect])
        #expect(first.events.first?.method == "GET")

        let next = UInt32(1001 + good.utf8.count)
        let second = send(watcher, bytes(evil), at: next)
        #expect(second.events.map(\.kind) == [.request, .block])
        #expect(second.events.last?.reason == "evil.example is not allowed")
        #expect(second.events.last?.path == "/x")
        #expect(reset(in: second.toNetwork)?.sequence == next)
        #expect(reset(in: second.toGuest) != nil)
    }

    @Test func aRequestSplitAcrossSegmentsIsStillChecked() {
        let watcher = web()
        _ = send(watcher, bytes(good), at: 1001)
        let next = UInt32(1001 + good.utf8.count)

        let partial = send(watcher, bytes("GET /x HTTP/1.1\r\nHo"), at: next)
        #expect(partial.toNetwork.count == 1)
        #expect(partial.events.isEmpty)

        let rest = send(watcher, bytes("st: evil.example\r\n\r\n"), at: next + 19)
        #expect(rest.events.last?.verdict == .blocked)
        #expect(reset(in: rest.toNetwork)?.sequence == (next + 19))
    }

    @Test func bodiesAreSkippedBeforeTheNextRequest() {
        let watcher = web()
        let post = "POST /u HTTP/1.1\r\nHost: github.com\r\nContent-Length: 5\r\n\r\nhel"
        #expect(send(watcher, bytes(post), at: 1001).toNetwork.count == 1)

        let body = send(watcher, bytes("lo"), at: UInt32(1001 + post.utf8.count))
        #expect(body.toNetwork.count == 1)
        #expect(body.events.isEmpty)

        let blocked = send(watcher, bytes(evil), at: UInt32(1001 + post.utf8.count + 2))
        #expect(blocked.events.last?.reason == "evil.example is not allowed")

        let chunky = web()
        let chunked =
            "POST /u HTTP/1.1\r\nHost: github.com\r\nTransfer-Encoding: chunked\r\n\r\n3;x=y\r\nabc\r\n0\r\nX-T: 1\r\n\r\n"
        #expect(send(chunky, bytes(chunked), at: 1001).toNetwork.count == 1)
        #expect(send(chunky, bytes(evil), at: UInt32(1001 + chunked.utf8.count)).events.last?.verdict == .blocked)

        let broken = web()
        let bad = "POST /u HTTP/1.1\r\nHost: github.com\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"
        #expect(send(broken, bytes(bad), at: 1001).events.last?.reason == "bad HTTP chunk")
    }

    @Test func monitorLogsEveryRequestAndBlocksNothing() {
        let watcher = web(TrafficPolicy())
        _ = send(watcher, bytes(good), at: 1001)

        let second = send(watcher, bytes(evil), at: UInt32(1001 + good.utf8.count))
        #expect(second.toNetwork.count == 1)
        #expect(second.events.map(\.kind) == [.request])
        #expect(second.events.first?.host == "evil.example")
        #expect(second.events.first?.path == "/x")

        let garbage = send(watcher, [0, 1, 2, 3, 13, 10, 13, 10], at: UInt32(1001 + good.utf8.count + evil.utf8.count))
        #expect(garbage.toNetwork.count == 1)
        #expect(garbage.events.isEmpty)

        let switched = watcher.update(allowList, now: now)
        #expect(switched.events.last?.reason == "HTTP connection from before the rules changed (rules changed)")
    }

    @Test func outOfOrderAndAlteredSegmentsOnAnHTTPConnection() throws {
        let watcher = web()
        let head = bytes(good)

        let late = send(watcher, Array(head.dropFirst(10)), at: 1011)
        #expect(late.toNetwork.isEmpty)
        #expect(send(watcher, Array(head.prefix(10)), at: 1001).toNetwork.count == 1)
        #expect(send(watcher, Array(head.dropFirst(10)), at: 1011).events.first?.verdict == .allowed)

        var altered = Array(head.prefix(10))
        altered[0] = UInt8(ascii: "P")
        let resent = send(watcher, altered, at: 1001)
        #expect(resent.events.first?.reason == "resent different data")
        #expect(resent.toNetwork.contains { reset(in: [$0]) != nil })

        let acked = web()
        _ = send(acked, head, at: 1001)
        let key = FlowKey(
            protocolNumber: Packet.protocolTCP, guestPort: 50_000, remote: address(github), remotePort: 80)
        #expect(acked.flows[key]?.clientBytes.count == head.count)

        ack(acked, UInt32(1001 + head.count))
        #expect(acked.flows[key]?.clientBytes.count == 0)
        #expect(acked.flows[key]?.http?.parsed == 0)
    }

    @Test func cleartextHTTP2AndCONNECT() {
        let preface = send(web(), bytes("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), at: 1001)
        #expect(preface.events.first?.reason == "HTTP without a host name")

        let tunnel = web()
        let connect = send(tunnel, bytes("CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n"), at: 1001)
        #expect(connect.events.first?.verdict == .allowed)
        #expect(send(tunnel, [0x16, 3, 1, 0, 5, 1, 2, 3, 4, 5], at: 1001 + 53).toNetwork.count == 1)
    }

    @Test func aCONNECTTunnelIsStillChecked() {
        let connect = bytes("CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n")
        let after = UInt32(1001 + connect.count)

        let allowed = web()
        _ = send(allowed, connect, at: 1001)
        let hello = send(allowed, TrafficSamples.clientHello(serverName: "github.com"), at: after)
        #expect(hello.toNetwork.count == 1)
        #expect(reset(in: hello.toNetwork) == nil)

        let foreignName = web()
        _ = send(foreignName, connect, at: 1001)
        let blocked = send(foreignName, TrafficSamples.clientHello(serverName: "evil.example"), at: after)
        #expect(blocked.events.last?.verdict == .blocked)
        #expect(reset(in: blocked.toNetwork) != nil)

        let plain = web()
        _ = send(plain, connect, at: 1001)
        let request = send(plain, bytes(evil), at: after)
        #expect(request.events.last?.verdict == .blocked)
        #expect(reset(in: request.toNetwork) != nil)

        let proxyFirst = web()
        _ = send(proxyFirst, connect, at: 1001)
        let established = Packet.tcp(
            source: address(github), destination: guestIP, sourcePort: 80, destinationPort: 50_000,
            sequence: 5000, acknowledgment: after, flags: TCPSegment.ack | 0x08,
            payload: bytes("HTTP/1.1 200 Connection established\r\n\r\n"))
        _ = proxyFirst.fromNetwork(networkFrame(from: github, Packet.protocolTCP, established), now: now)
        #expect(
            send(proxyFirst, TrafficSamples.clientHello(serverName: "evil.example"), at: after).events.last?.verdict
                == .blocked)

        let watched = web(TrafficPolicy())
        _ = send(watched, connect, at: 1001)
        #expect(send(watched, TrafficSamples.clientHello(serverName: "evil.example"), at: after).toNetwork.count == 1)
    }

    @Test func ambiguousHTTPFramingIsRefused() {
        let twoHosts = "GET / HTTP/1.1\r\nHost: github.com\r\nHost: evil.example\r\n\r\n"
        let strict = send(web(), bytes(twoHosts), at: 1001)
        #expect(strict.events.last?.reason == "not an HTTP request")
        #expect(reset(in: strict.toNetwork) != nil)

        #expect(send(web(TrafficPolicy()), bytes(twoHosts), at: 1001).toNetwork.count == 1)
    }

    @Test func aBlockedNameCannotHideBehindATrailingDotOrAnotherHost() {
        let blockList = TrafficPolicy(mode: .blocklist, blocked: ["evil.example"])
        let dotted = "GET / HTTP/1.1\r\nHost: Evil.Example.\r\n\r\n"
        let absolute = "GET http://evil.example/ HTTP/1.1\r\nHost: other.example\r\n\r\n"

        let dottedOutput = send(web(blockList), bytes(dotted), at: 1001)
        let absoluteOutput = send(web(blockList), bytes(absolute), at: 1001)

        #expect(dottedOutput.events.last?.verdict == .blocked)
        #expect(reset(in: dottedOutput.toNetwork) != nil)
        #expect(absoluteOutput.events.last?.reason == "not an HTTP request")
        #expect(reset(in: absoluteOutput.toNetwork) != nil)
    }

    @Test func serverRepliesDoNotEndHTTPInspection() {
        let watcher = web()
        _ = send(watcher, bytes(good), at: 1001)
        let next = UInt32(1001 + good.utf8.count)
        ack(watcher, next)

        let reply = Packet.tcp(
            source: address(github), destination: guestIP, sourcePort: 80, destinationPort: 50_000,
            sequence: 5000, acknowledgment: next, flags: TCPSegment.ack | 0x08,
            payload: bytes("HTTP/1.1 200 OK\r\n\r\n"))
        let response = watcher.fromNetwork(networkFrame(from: github, Packet.protocolTCP, reply), now: now)
        #expect(response.toGuest.count == 1)
        #expect(response.events.isEmpty)

        let second = send(watcher, bytes(evil), at: next)
        #expect(second.events.last?.verdict == .blocked)
        #expect(second.toNetwork.contains { reset(in: [$0]) != nil })
    }

    @Test func aWebSocketUpgradeKeepsItsConnection() {
        let upgrade =
            "GET /ws HTTP/1.1\r\nHost: github.com\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n"
        let frames: [UInt8] = [0x82, 0x84, 1, 2, 3, 4, 13, 10, 13, 10]
        let socket = web()

        #expect(send(socket, bytes(upgrade), at: 1001).events.first?.verdict == .allowed)
        let data = send(socket, frames, at: UInt32(1001 + upgrade.utf8.count))

        #expect(data.toNetwork.count == 1)
        #expect(reset(in: data.toNetwork) == nil)
        #expect(data.events.isEmpty)
    }

    @Test func anUpgradeNeedsBothFieldsAndAnAllowedHost() {
        let frames: [UInt8] = [0x82, 0x84, 1, 2, 3, 4, 13, 10, 13, 10]
        let withoutConnection = "GET /ws HTTP/1.1\r\nHost: github.com\r\nUpgrade: websocket\r\n\r\n"
        let blockedHost = "GET /ws HTTP/1.1\r\nHost: evil.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
        let plain = web()
        let blocklist = web(TrafficPolicy(mode: .blocklist, blocked: ["evil.example"]))

        _ = send(plain, bytes(withoutConnection), at: 1001)
        let garbage = send(plain, frames, at: UInt32(1001 + withoutConnection.utf8.count))
        let refused = send(blocklist, bytes(blockedHost), at: 1001)

        #expect(garbage.events.last?.reason == "not an HTTP request")
        #expect(reset(in: garbage.toNetwork) != nil)
        #expect(refused.events.last?.verdict == .blocked)
        #expect(reset(in: refused.toNetwork) != nil)
    }

    @Test func monitorStopsWatchingAResendWithDifferentData() {
        let watcher = connectedToGitHub(TrafficPolicy())
        _ = hello(watcher, TrafficSamples.clientHello(serverName: "github.com"))

        let decoy = hello(watcher, TrafficSamples.clientHello(serverName: "evil.example"))

        #expect(decoy.toNetwork.count == 1)
        #expect(reset(in: decoy.toGuest) == nil)
        #expect(decoy.events.allSatisfy { $0.verdict != .blocked })
    }

    @Test func loopbackAndZeroAddressesCountAsThisMac() {
        let watcher = inspector(TrafficPolicy(mode: .blocklist))

        let loopback = watcher.fromGuest(guestTCP(to: "127.0.0.2", port: 8080, flags: TCPSegment.syn), now: now)
        let zero = watcher.fromGuest(guestTCP(to: "0.0.0.1", port: 8080, flags: TCPSegment.syn), now: now)

        #expect(loopback.toNetwork.isEmpty)
        #expect(loopback.events.first?.reason == "this Mac is blocked")
        #expect(zero.toNetwork.isEmpty)
        #expect(zero.events.first?.reason == "this Mac is blocked")
    }

    @Test func aFullListOfLookupsStillMatchesTheNewestAnswer() {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        for id in 0..<UInt16(TrafficInspector.maximumPendingQueries) {
            _ = watcher.fromGuest(lookup("github.com", id: id, port: 41_000), now: now)
        }
        let query = TrafficSamples.dnsQuery("github.com", id: 0xbeef)
        _ = watcher.fromGuest(lookup(query, port: 40_000), now: now)

        let answer = watcher.fromNetwork(answerFrame(to: query, port: 40_000), now: now.addingTimeInterval(1))

        #expect(answer.toGuest.count == 1)
        #expect(watcher.pendingQueries.count <= TrafficInspector.maximumPendingQueries)
        #expect(watcher.fromGuest(guestTCP(to: github, flags: TCPSegment.syn), now: now).toNetwork.count == 1)
    }

    @Test func aSlowAnswerWithinThirtySecondsIsStillMatched() {
        let watcher = inspector(TrafficPolicy(mode: .allowlist, allowed: ["github.com"]))
        let query = TrafficSamples.dnsQuery("github.com", id: 0x5151)
        _ = watcher.fromGuest(lookup(query, port: 40_000), now: now)
        _ = watcher.expire(now: now.addingTimeInterval(20))

        let answer = watcher.fromNetwork(answerFrame(to: query, port: 40_000), now: now.addingTimeInterval(20))

        #expect(answer.toGuest.count == 1)
        #expect(answer.events.first?.answers == [github])
    }

    private func lookup(_ name: String, id: UInt16, port: UInt16) -> [UInt8] {
        lookup(TrafficSamples.dnsQuery(name, id: id), port: port)
    }

    private func lookup(_ query: [UInt8], port: UInt16) -> [UInt8] {
        guestFrame(
            to: "10.88.0.1", Packet.protocolUDP, Packet.udp(sourcePort: port, destinationPort: 53, payload: query))
    }

    private func answerFrame(to query: [UInt8], port: UInt16) -> [UInt8] {
        networkFrame(
            from: "10.88.0.1", Packet.protocolUDP,
            Packet.udp(
                sourcePort: 53, destinationPort: port,
                payload: TrafficSamples.dnsAnswer(to: query, addresses: [github])))
    }
}
