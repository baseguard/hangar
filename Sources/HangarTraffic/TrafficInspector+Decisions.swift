import Foundation
import HangarPackets

extension TrafficInspector {
    func decide(_ flow: TrafficFlow) {
        let (verdict, reason) = verdict(for: flow)
        flow.verdict = verdict
        flow.reason = reason
    }

    private typealias Decision = (TrafficEvent.Verdict, String?)

    private func verdict(for flow: TrafficFlow) -> Decision {
        if flow.direction == .inbound { return inboundVerdict(for: flow) }
        if policy.isolated { return (.blocked, "isolated") }
        guard policy.enforces else { return (.allowed, nil) }

        if let decision = transportVerdict(for: flow) { return decision }
        if let decision = nearbyVerdict(for: flow) { return decision }
        return remoteVerdict(for: flow)
    }

    private func inboundVerdict(for flow: TrafficFlow) -> Decision {
        let remote = flow.key.remote
        let protocolNumber = flow.key.protocolNumber
        let fromHost = isHost(remote)
        if fromHost, protocolNumber != Packet.protocolUDP { return (.allowed, nil) }
        if policy.isolated { return (.blocked, "isolated") }
        guard policy.enforces else { return (.allowed, nil) }

        if protocolNumber == Packet.protocolUDP, !policy.allowsUDP { return (.blocked, "UDP is blocked") }
        if fromHost { return policy.allowsHost ? (.allowed, nil) : (.blocked, "this Mac is blocked") }
        if isLocal(remote) { return vmVerdict(remote) }
        return (.blocked, "unexpected incoming traffic")
    }

    private func transportVerdict(for flow: TrafficFlow) -> Decision? {
        let protocolNumber = flow.key.protocolNumber
        let port = flow.key.remotePort
        if protocolNumber == Packet.protocolUDP, !policy.allowsUDP, port != Packet.dnsPort {
            return (.blocked, "UDP is blocked")
        }
        if protocolNumber == Packet.protocolICMP, !Self.allowedICMPTypes.contains(port) {
            return (.blocked, "ICMP type \(port) is blocked")
        }
        guard port == Packet.dnsPort else { return nil }

        if protocolNumber == Packet.protocolUDP { return (.blocked, "not a DNS query") }
        if protocolNumber == Packet.protocolTCP, policy.mode == .allowlist {
            return (.blocked, "DNS over TCP is blocked")
        }
        if protocolNumber == Packet.protocolTCP, flow.key.remote != subnet.gateway.value {
            return (.blocked, "DNS only through this Mac")
        }
        return nil
    }

    private func nearbyVerdict(for flow: TrafficFlow) -> Decision? {
        let remote = flow.key.remote
        if isHost(remote) {
            let dns = flow.key.protocolNumber == Packet.protocolTCP && flow.key.remotePort == Packet.dnsPort
            return dns || policy.allowsHost ? (.allowed, nil) : (.blocked, "this Mac is blocked")
        }
        if isLocal(remote) { return vmVerdict(remote) }
        guard isPrivate(remote) else { return nil }

        if let rule = rules.blocked.first(where: { $0.matches(address: remote) }) {
            return (.blocked, "blocked by \(rule.description)")
        }
        let allowed = policy.allowsLocalNetwork || rules.allowed.contains { $0.matches(address: remote) }
        return allowed ? (.allowed, nil) : (.blocked, "the local network is blocked")
    }

    private func vmVerdict(_ address: UInt32) -> Decision {
        canReachVM(address) ? (.allowed, nil) : (.blocked, "other VMs are blocked")
    }

    /// Every VM when other VMs are allowed, or those an allow rule names. A rule reaching past Hangar's network, like a
    /// whole private range for the local network, doesn't open the VMs in it.
    func canReachVM(_ address: UInt32) -> Bool {
        if policy.isolated { return false }
        guard policy.enforces else { return true }
        return policy.allowsVMs || rules.allowed.contains { $0.isWithin(subnet) && $0.matches(address: address) }
    }

    private func remoteVerdict(for flow: TrafficFlow) -> Decision {
        let remote = flow.key.remote
        if flow.key.protocolNumber == Packet.protocolUDP, flow.key.remotePort == 443, !policy.allowsQUIC {
            return (.blocked, "QUIC is blocked")
        }

        let names = [flow.serverName].compactMap { $0 } + flow.names
        if let rule = rules.blocked.first(where: { rule in
            rule.matches(address: remote) || names.contains(where: rule.matches(name:))
        }) {
            return (.blocked, "blocked by \(rule.description)")
        }

        guard policy.mode == .allowlist else { return (.allowed, nil) }
        if rules.allowed.contains(where: { $0.matches(address: remote) }) { return (.allowed, nil) }
        return allowlistVerdict(for: flow)
    }

    private func allowlistVerdict(for flow: TrafficFlow) -> Decision {
        switch flow.application {
        case .tls?, .http?:
            guard let serverName = flow.serverName else {
                return (.blocked, "\(flow.application == .tls ? "TLS" : "HTTP") without a host name")
            }
            return isAllowed(serverName) ? (.allowed, nil) : (.blocked, "\(serverName) is not allowed")
        case .other?, nil:
            if flow.trustedNames.contains(where: isAllowed) { return (.allowed, nil) }
            if let name = flow.names.first(where: isAllowed) {
                return (.blocked, "\(name) was not looked up through this Mac")
            }
            return (
                .blocked,
                flow.names.first.map { "\($0) is not allowed" } ?? "no allowed name for \(IPv4Address(flow.key.remote))"
            )
        }
    }

    private func isAllowed(_ name: String) -> Bool {
        rules.allowed.contains { $0.matches(name: name) }
    }

    func dnsVerdict(name: String, server: UInt32) -> (TrafficEvent.Verdict, String?) {
        if policy.isolated { return (.blocked, "isolated") }
        guard policy.enforces else { return (.allowed, nil) }
        guard server == subnet.gateway.value else { return (.blocked, "DNS only through this Mac") }
        let lookedUp = [name] + [aliases[name]?.origin].compactMap { $0 }
        if let rule = rules.blocked.first(where: { rule in lookedUp.contains(where: rule.matches(name:)) }) {
            return (.blocked, "blocked by \(rule.description)")
        }
        guard policy.mode == .allowlist else { return (.allowed, nil) }
        return lookedUp.contains(where: isAllowed) ? (.allowed, nil) : (.blocked, "\(name) is not allowed")
    }

    /// See `asksForServiceRecord`.
    func serviceRecordVerdict(_ question: DNSMessage.Question) -> (TrafficEvent.Verdict, String?)? {
        asksForServiceRecord(of: question) ? (.blocked, "a service record for a host with a secret") : nil
    }

    func knownNames(for address: UInt32, now: Date) -> NameEntry? {
        guard let entry = names[address], entry.expires > now else { return nil }
        return entry
    }

    // 127/8 and 0/8 can only mean this Mac when they arrive from a guest.
    func isHost(_ address: UInt32) -> Bool {
        let firstOctet = address >> 24
        return address == subnet.gateway.value || hostAddresses.contains(address) || firstOctet == 127
            || firstOctet == 0
    }

    func isLocal(_ address: UInt32) -> Bool {
        let ip = IPv4Address(address)
        return subnet.contains(ip) || ip.isMulticast || ip == IPv4Address.limitedBroadcast
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16 and 100.64/10 (carrier NAT).
    func isPrivate(_ address: UInt32) -> Bool {
        address & 0xff00_0000 == 0x0a00_0000 || address & 0xfff0_0000 == 0xac10_0000
            || address & 0xffff_0000 == 0xc0a8_0000
            || address & 0xffff_0000 == 0xa9fe_0000 || address & 0xffc0_0000 == 0x6440_0000
    }

    func isLocalBroadcast(_ address: UInt32) -> Bool {
        let ip = IPv4Address(address)
        return ip.isLinkLocalMulticast || ip == IPv4Address.limitedBroadcast || address == subnet.broadcast.value
    }

    func guestDNS(_ frame: [UInt8], _ udp: UDPDatagram, now: Date, output: inout Output) -> Bool {
        let bytes = Array(udp.ip.bytes[udp.payload])
        guard let message = DNSMessage(bytes), !message.isResponse else { return false }

        let question = message.question
        let server = udp.ip.destination
        let (verdict, reason) = serviceRecordVerdict(question) ?? dnsVerdict(name: question.name, server: server)
        if verdict == .blocked {
            var event = dnsEvent(
                PendingQuery(name: question.name, type: question.type, server: server, askedAt: now), answers: nil,
                reason: reason)
            event.verdict = .blocked
            emit(event, now: now, output: &output)
            answerBlockedQuery(bytes, frame, udp, output: &output)
            return true
        }

        let query = PendingQuery(
            name: question.name, type: question.type, server: server, askedAt: now,
            gatewayMAC: Array(frame[Packet.destinationMAC]))

        recordPending(query, key: UInt32(udp.sourcePort) << 16 | UInt32(message.id), now: now, output: &output)

        output.toNetwork.append(frame)

        return true
    }

    /// The refusal comes back as the server's own answer: REFUSED while isolated, otherwise "no such name".
    private func answerBlockedQuery(_ query: [UInt8], _ frame: [UInt8], _ udp: UDPDatagram, output: inout Output) {
        let code = policy.isolated ? DNSMessage.refused : DNSMessage.nameError
        guard let reply = DNSMessage.refusal(to: query, code: code) else { return }

        let datagram = Packet.udp(sourcePort: Packet.dnsPort, destinationPort: udp.sourcePort, payload: reply)
        let packet = Packet.ipv4(
            source: udp.ip.destination, destination: udp.ip.source, protocol: Packet.protocolUDP, payload: datagram)
        output.toGuest.append(
            Packet.ethernet(
                destination: guestMAC, source: Array(frame[Packet.destinationMAC]),
                type: Packet.etherTypeIPv4, payload: packet))
    }

    // An answer is only trusted when it matches a recorded query, so a full list makes room rather than leaving a query
    // unrecorded, whose answer would then be dropped.
    private func recordPending(_ query: PendingQuery, key: UInt32, now: Date, output: inout Output) {
        if pendingQueries[key] == nil, pendingQueries.count >= Self.maximumPendingQueries {
            dropOldestPending(now: now, output: &output)
        }
        pendingQueries[key] = query
    }

    // A quarter goes at once, so a guest flooding queries costs one sort per thousand queries rather than a scan each.
    private func dropOldestPending(now: Date, output: inout Output) {
        let byAge = pendingQueries.sorted { $0.value.askedAt < $1.value.askedAt }
        for (key, query) in byAge.prefix(Self.maximumPendingQueries / 4) {
            emit(dnsEvent(query, answers: nil, reason: "no answer"), now: now, output: &output)
            pendingQueries[key] = nil
        }
    }

    func networkDNS(_ frame: [UInt8], _ udp: UDPDatagram, now: Date, output: inout Output) -> Bool {
        guard let message = DNSMessage(Array(udp.ip.bytes[udp.payload])), message.isResponse else { return false }

        let key = UInt32(udp.destinationPort) << 16 | UInt32(message.id)
        guard let query = pendingQueries[key], query.server == udp.ip.source,
            frame[Packet.sourceMAC].elementsEqual(query.gatewayMAC)
        else {
            if !policy.enforces { output.toGuest.append(frame) }
            return true
        }
        pendingQueries[key] = nil
        learn(from: message, answering: query, now: now)
        emit(answerEvent(for: query, message), now: now, output: &output)
        output.toGuest.append(frame)

        return true
    }

    /// Remembers which names the answer's addresses belong to. Aliases, and names that count as looked up
    /// through this Mac, are kept only from this Mac's own resolver.
    private func learn(from message: DNSMessage, answering query: PendingQuery, now: Date) {
        let shortestTTL = message.answers.map(\.ttl).min() ?? 0
        let ttl = TimeInterval(min(max(shortestTTL, Self.shortestNameLife), Self.longestNameLife))
        let expires = now.addingTimeInterval(ttl)
        let trusted = query.server == subnet.gateway.value
        let origin =
            aliases[query.name]?.origin
            ?? query.name.split(separator: ".").drop(while: { $0.hasPrefix("_") }).joined(separator: ".")

        if trusted {
            for alias in message.answers.compactMap(\.alias)
            where aliases[alias] != nil || aliases.count < Self.maximumNames {
                aliases[alias] = (origin, expires)
            }
        }

        let learned = origin == query.name ? [query.name] : [origin, query.name]
        remember(learned, for: message.answers.compactMap(\.address), trusted: trusted, until: expires, now: now)
    }

    /// The newest names come first, and an address keeps at most `namesPerAddress`.
    private func remember(_ learned: [String], for addresses: [UInt32], trusted: Bool, until expires: Date, now: Date) {
        for address in addresses where names[address] != nil || names.count < Self.maximumNames {
            var entry = names[address] ?? NameEntry(expires: now)
            entry.names = Array((learned + entry.names.filter { !learned.contains($0) }).prefix(Self.namesPerAddress))
            if trusted {
                let kept = entry.trusted.filter { !learned.contains($0) }
                entry.trusted = Array((learned + kept).prefix(Self.namesPerAddress))
            }
            entry.expires = max(entry.expires, expires)
            names[address] = entry
        }
    }

    private func answerEvent(for query: PendingQuery, _ message: DNSMessage) -> TrafficEvent {
        let answers =
            message.answers.compactMap(\.alias)
            + message.answers.compactMap(\.address).map { IPv4Address($0).description }
            + message.answers.compactMap(\.address6)
        return dnsEvent(query, answers: answers, reason: Self.reason(forResponseCode: message.responseCode))
    }

    private static func reason(forResponseCode code: UInt8) -> String? {
        switch code {
        case 0: nil
        case DNSMessage.serverFailure: "server failure"
        case DNSMessage.nameError: "no such domain"
        case DNSMessage.refused: "refused"
        default: "error \(code)"
        }
    }

    func refuse(
        _ flow: TrafficFlow, _ reason: String, _ frame: [UInt8], _ tcp: TCPSegment,
        now: Date, output: inout Output
    ) -> Bool {
        fail(flow, reason, now: now, output: &output)
        output.toGuest.append(resetToSender(of: frame, tcp))
        output.toNetwork.append(resetToReceiver(of: frame, tcp, sequence: tcp.sequence))
        release(flow)
        return false
    }

    func dnsEvent(_ query: PendingQuery, answers: [String]?, reason: String?) -> TrafficEvent {
        TrafficEvent(
            time: query.askedAt, kind: .dns, address: IPv4Address(query.server).description, query: query.name,
            queryType: DNSMessage.typeName(query.type), answers: answers, verdict: .allowed, reason: reason)
    }

    func resetToSender(of frame: [UInt8], _ tcp: TCPSegment) -> [UInt8] {
        let length = UInt32(tcp.payload.count) + (tcp.has(TCPSegment.syn) ? 1 : 0) + (tcp.has(TCPSegment.fin) ? 1 : 0)
        let acknowledges = tcp.has(TCPSegment.ack)
        let segment = Packet.tcp(
            source: tcp.ip.destination, destination: tcp.ip.source,
            sourcePort: tcp.destinationPort, destinationPort: tcp.sourcePort,
            sequence: acknowledges ? tcp.acknowledgment : 0,
            acknowledgment: acknowledges ? 0 : tcp.sequence &+ length,
            flags: acknowledges ? TCPSegment.rst : TCPSegment.rst | TCPSegment.ack)
        let packet = Packet.ipv4(
            source: tcp.ip.destination, destination: tcp.ip.source, protocol: Packet.protocolTCP, payload: segment)
        return Packet.ethernet(
            destination: Array(frame[Packet.sourceMAC]), source: Array(frame[Packet.destinationMAC]),
            type: Packet.etherTypeIPv4, payload: packet)
    }

    func resetToReceiver(of frame: [UInt8], _ tcp: TCPSegment, sequence: UInt32) -> [UInt8] {
        let segment = Packet.tcp(
            source: tcp.ip.source, destination: tcp.ip.destination,
            sourcePort: tcp.sourcePort, destinationPort: tcp.destinationPort,
            sequence: sequence, acknowledgment: 0, flags: TCPSegment.rst)
        let packet = Packet.ipv4(
            source: tcp.ip.source, destination: tcp.ip.destination, protocol: Packet.protocolTCP, payload: segment)
        return Packet.ethernet(
            destination: Array(frame[Packet.destinationMAC]), source: Array(frame[Packet.sourceMAC]),
            type: Packet.etherTypeIPv4, payload: packet)
    }
}
