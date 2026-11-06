import Foundation
import HangarPackets
import HangarSupport

/// The guest's connections: TCP flows and datagram exchanges, opened on the first frame, matched on the rest and
/// dropped when idle.
extension TrafficInspector {
    func guestTCP(_ frame: [UInt8], _ tcp: TCPSegment, now: Date, output: inout Output) {
        let key = FlowKey(
            protocolNumber: Packet.protocolTCP, guestPort: tcp.sourcePort, remote: tcp.ip.destination,
            remotePort: tcp.destinationPort)
        let opening = tcp.has(TCPSegment.syn) && !tcp.has(TCPSegment.ack)

        if let previous = flows[key], opening, isNewConnection(tcp, on: previous) {
            replace(previous, now: now, output: &output)
        }
        guard let flow = flowForGuestSegment(key, frame, tcp, opening: opening, now: now, output: &output) else {
            return
        }

        flow.lastSeen = now
        guard flow.verdict == .allowed else {
            if !tcp.has(TCPSegment.rst) { output.toGuest.append(resetToSender(of: frame, tcp)) }
            return
        }
        if isAheadOfTheServer(tcp, on: flow) {
            reportSentAheadOfTheServer(flow, now: now, output: &output)
            return
        }

        let payload = tcp.payload
        if !payload.isEmpty, !inspectClientData(flow, frame, tcp, now: now, output: &output) { return }
        flow.sent += UInt64(payload.count)
        if tcp.has(TCPSegment.fin) { flow.hasGuestFinished = true }
        if tcp.has(TCPSegment.rst) { flow.wasReset = true }
        output.toNetwork.append(frame)
    }

    /// The segment's flow: the one open, or one opened by a SYN. A segment of no flow is dropped; under rules the
    /// guest gets a reset for it, since its connection was never checked.
    private func flowForGuestSegment(
        _ key: FlowKey, _ frame: [UInt8], _ tcp: TCPSegment, opening: Bool, now: Date, output: inout Output
    ) -> TrafficFlow? {
        if let existing = flows[key] { return existing }
        if tcp.has(TCPSegment.rst) {
            if !policy.enforces { output.toNetwork.append(frame) }
            return nil
        }
        if !opening, policy.enforces {
            output.toGuest.append(resetToSender(of: frame, tcp))
            return nil
        }

        guard let opened = open(key, direction: .outbound, opening: opening ? tcp : nil, now: now, output: &output)
        else { return nil }
        if opening { divertIfForSecretHost(opened, now: now) }
        return opened
    }

    /// A SYN that doesn't resend the flow's own opening is the guest reusing the port for a new connection.
    private func isNewConnection(_ opening: TCPSegment, on flow: TrafficFlow) -> Bool {
        flow.isClosed || flow.clientStart != opening.sequence &+ 1
    }

    private func replace(_ flow: TrafficFlow, now: Date, output: inout Output) {
        if !flow.isClosed, flow.reason == nil { flow.reason = "replaced by a new connection" }
        close(flow, now: now, output: &output)
        flows[flow.key] = nil
    }

    /// The server may still hold an older connection on the same ports that the inspector no longer follows, so until
    /// it accepts the guest's SYN no data passes either way. This rules out a simultaneous open on purpose.
    private func isWaitingForTheServer(_ flow: TrafficFlow) -> Bool {
        policy.enforces && flow.isFollowedFromItsSYN && !flow.isEstablished
    }

    private func isAheadOfTheServer(_ tcp: TCPSegment, on flow: TrafficFlow) -> Bool {
        isWaitingForTheServer(flow) && !tcp.has(TCPSegment.syn) && !tcp.has(TCPSegment.rst)
    }

    private func isFromAnOlderConnection(_ tcp: TCPSegment, on flow: TrafficFlow) -> Bool {
        isWaitingForTheServer(flow) && !establishes(tcp, flow) && !tcp.has(TCPSegment.rst)
    }

    /// Only the server's SYN-ACK to the guest's own SYN establishes a connection the guest opened.
    private func establishes(_ tcp: TCPSegment, _ flow: TrafficFlow) -> Bool {
        guard let clientStart = flow.clientStart else { return tcp.has(TCPSegment.ack) || !tcp.payload.isEmpty }
        let answersTheSYN = tcp.acknowledgment == clientStart || tcp.acknowledgment == flow.openingEnd
        return tcp.has(TCPSegment.syn) && tcp.has(TCPSegment.ack) && answersTheSYN
    }

    private func reportSentAheadOfTheServer(_ flow: TrafficFlow, now: Date, output: inout Output) {
        guard !flow.hasSentAheadOfTheServer else { return }
        flow.hasSentAheadOfTheServer = true
        var event = flow.event(.block, now: now)
        event.verdict = .blocked
        event.reason = "sent before the server answered"
        emit(event, now: now, output: &output)
    }

    func networkTCP(_ frame: [UInt8], _ tcp: TCPSegment, now: Date, output: inout Output) {
        let key = FlowKey(
            protocolNumber: Packet.protocolTCP, guestPort: tcp.destinationPort, remote: tcp.ip.source,
            remotePort: tcp.sourcePort)
        guard let flow = flows[key] else {
            openInboundConnection(key, frame, tcp, now: now, output: &output)
            return
        }

        flow.lastSeen = now
        guard flow.verdict == .allowed else {
            if !tcp.has(TCPSegment.rst) {
                output.toGuest.append(resetToReceiver(of: frame, tcp, sequence: tcp.sequence))
            }
            return
        }
        if isFromAnOlderConnection(tcp, on: flow) {
            // The guest answers a stale connection's bare ACK or FIN with the RST that clears it on the server.
            if tcp.payload.isEmpty, !tcp.has(TCPSegment.syn) { output.toGuest.append(frame) }
            return
        }

        trackServerSegment(tcp, on: flow, now: now, output: &output)
        output.toGuest.append(frame)
    }

    /// A segment of no flow opens one only as a SYN; the rest pass only while nothing is enforced.
    private func openInboundConnection(
        _ key: FlowKey, _ frame: [UInt8], _ tcp: TCPSegment, now: Date, output: inout Output
    ) {
        guard tcp.has(TCPSegment.syn), !tcp.has(TCPSegment.ack) else {
            if !policy.enforces { output.toGuest.append(frame) }
            return
        }
        guard let flow = open(key, direction: .inbound, opening: nil, now: now, output: &output) else { return }
        if flow.verdict == .allowed {
            output.toGuest.append(frame)
        } else {
            output.toNetwork.append(resetToSender(of: frame, tcp))
        }
    }

    private func trackServerSegment(_ tcp: TCPSegment, on flow: TrafficFlow, now: Date, output: inout Output) {
        let payload = tcp.payload.count
        if establishes(tcp, flow) { flow.isEstablished = true }
        if payload > 0 { serverSpokeFirst(flow, now: now, output: &output) }
        if tcp.has(TCPSegment.ack) { acknowledged(flow, upTo: tcp.acknowledgment) }
        flow.received += UInt64(payload)
        if tcp.has(TCPSegment.fin) { flow.hasRemoteFinished = true }
        if tcp.has(TCPSegment.rst) { flow.wasReset = true }
    }

    func guestDatagram(_ frame: [UInt8], key: FlowKey, payload: Int, now: Date, output: inout Output) {
        guard let flow = flows[key] ?? open(key, direction: .outbound, opening: nil, now: now, output: &output)
        else { return }
        flow.lastSeen = now
        guard flow.verdict == .allowed else { return }
        flow.sent += UInt64(payload)
        output.toNetwork.append(frame)
    }

    func networkDatagram(_ frame: [UInt8], key: FlowKey, payload: Int, now: Date, output: inout Output) {
        guard let flow = flows[key] ?? open(key, direction: .inbound, opening: nil, now: now, output: &output)
        else { return }
        flow.lastSeen = now
        guard flow.verdict == .allowed else { return }
        flow.received += UInt64(payload)
        output.toGuest.append(frame)
    }

    func open(
        _ key: FlowKey, direction: TrafficFlow.Direction, opening: TCPSegment?, now: Date, output: inout Output
    ) -> TrafficFlow? {
        if flows.count >= Self.maximumFlows, now.timeIntervalSince(lastPrune) > Self.pruneInterval {
            lastPrune = now
            removeIdleFlows(now: now, output: &output)
        }
        guard flows.count < Self.maximumFlows else {
            if now.timeIntervalSince(lastFullReport) > Self.fullTableReportInterval {
                lastFullReport = now
                emit(
                    TrafficEvent(time: now, kind: .block, verdict: .blocked, reason: "too many connections at once"),
                    now: now, output: &output)
            }
            return nil
        }
        flowsOpened += 1
        let known = direction == .outbound ? knownNames(for: key.remote, now: now) : nil
        let flow = TrafficFlow(
            id: "\(flowIDPrefix)-\(flowsOpened)", key: key, direction: direction,
            names: known?.names ?? [], trustedNames: known?.trusted ?? [], now: now)
        if let opening {
            let clientStart = opening.sequence &+ 1
            flow.clientStart = clientStart
            flow.openingEnd = clientStart &+ UInt32(opening.payload.count)
            flow.bufferStart = clientStart
            if key.remotePort == Packet.dnsPort {
                flow.dns = DNSStream()
            } else {
                flow.isInspecting = true
            }
        }
        decide(flow)
        flow.isQuiet = flow.verdict == .allowed && isLocalBroadcast(key.remote)
        if flow.verdict == .blocked || !flow.isInspecting { report(flow, now: now, output: &output) }
        flows[key] = flow
        return flow
    }

    func removeIdleFlows(now: Date, output: inout Output) {
        for (key, flow) in flows where now.timeIntervalSince(flow.lastSeen) > flow.idleLimit() {
            close(flow, now: now, output: &output)
            flows[key] = nil
        }
    }
}
