import Foundation
import HangarPackets

struct HTTPStream {
    enum Body {
        case head
        case length(Int)
        case chunkSize
        case chunkData(Int)
        case chunkEnd
        case trailers
        case tunnel
    }

    var body = Body.head
    var parsed = 0
    var requests = 0
}

/// DNS over TCP: each query is a 2-byte length and the message, read from the flow's buffered stream.
struct DNSStream {
    var parsed = 0
}

extension TrafficInspector {
    static let maximumBufferPerFlow = 4 << 20
    static let maximumLine = 1024
    static let maximumDNSMessage = 4096

    func inspectClientData(_ flow: TrafficFlow, _ frame: [UInt8], _ tcp: TCPSegment, now: Date, output: inout Output)
        -> Bool
    {
        let data = tcp.ip.bytes[tcp.payload]
        guard flow.isFollowedFromItsSYN else {
            guard flow.key.remotePort == Packet.dnsPort, policy.enforces else { return true }
            // Where each query starts can only be read from the first byte of the stream.
            return refuse(flow, "DNS over TCP seen mid-stream", frame, tcp, now: now, output: &output)
        }

        let nextClientSequence = flow.bufferStart &+ UInt32(flow.clientBytes.count)
        let position = Self.position(of: tcp, after: flow.bufferStart)
        // Bytes before the buffer were inspected when they were first sent.
        if position.upperBound <= 0 { return true }
        if !resendsTheSameBytes(data, at: position, of: flow) {
            stopOrFail(flow, "resent different data", now: now, output: &output)
        }
        if flow.verdict == .allowed, flow.isInspecting || flow.dns != nil,
            !inspectFreshBytes(data, at: position, of: flow, now: now, output: &output)
        {
            return false
        }

        guard flow.verdict == .allowed else {
            output.toGuest.append(resetToSender(of: frame, tcp))
            output.toNetwork.append(resetToReceiver(of: frame, tcp, sequence: nextClientSequence))
            release(flow)
            return false
        }
        return true
    }

    /// Where the segment's data lies, counted from the first byte the flow still buffers; negative is before it.
    static func position(of tcp: TCPSegment, after bufferStart: UInt32) -> Range<Int> {
        let sequence = tcp.sequence &+ (tcp.has(TCPSegment.syn) ? 1 : 0)
        let begin = Int(Int32(bitPattern: sequence &- bufferStart))
        return begin..<(begin + tcp.payload.count)
    }

    private func resendsTheSameBytes(_ data: ArraySlice<UInt8>, at position: Range<Int>, of flow: TrafficFlow) -> Bool {
        let buffered = position.clamped(to: 0..<flow.clientBytes.count)
        guard !buffered.isEmpty else { return true }
        let resent = data.dropFirst(buffered.lowerBound - position.lowerBound).prefix(buffered.count)
        return resent.elementsEqual(flow.clientBytes[buffered])
    }

    /// False holds the segment back: it leaves a gap, or the buffer is full while rules are enforced.
    private func inspectFreshBytes(
        _ data: ArraySlice<UInt8>, at position: Range<Int>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> Bool {
        let count = flow.clientBytes.count
        if position.lowerBound > count { return false }
        guard position.upperBound > count else { return true }

        let fresh = data.suffix(position.upperBound - count)
        if count + fresh.count > Self.maximumBufferPerFlow || bufferedBytes + fresh.count > Self.maximumBufferedBytes {
            guard !policy.enforces else { return false }
            stopInspecting(flow)
            return true
        }
        flow.clientBytes += fresh
        bufferedBytes += fresh.count
        inspect(flow, now: now, output: &output)
        return true
    }

    func acknowledged(_ flow: TrafficFlow, upTo acknowledgment: UInt32) {
        guard !flow.clientBytes.isEmpty else { return }
        let acked = Int(Int32(bitPattern: acknowledgment &- flow.bufferStart))
        let keep = flow.http?.parsed ?? flow.dns?.parsed ?? (flow.isInspecting ? 0 : flow.clientBytes.count)
        let drop = min(acked, keep, flow.clientBytes.count)
        guard drop > 0 else { return }
        flow.clientBytes.removeFirst(drop)
        flow.bufferStart &+= UInt32(drop)
        flow.http?.parsed -= drop
        flow.dns?.parsed -= drop
        bufferedBytes -= drop
    }

    func serverSpokeFirst(_ flow: TrafficFlow, now: Date, output: inout Output) {
        guard flow.isInspecting, flow.http == nil, flow.clientBytes.isEmpty, flow.bufferStart == flow.clientStart else {
            return
        }
        finishSniffing(flow, as: .unknown, now: now, output: &output)
    }

    private func inspect(_ flow: TrafficFlow, now: Date, output: inout Output) {
        if flow.dns != nil { return inspectDNS(flow, now: now, output: &output) }
        if flow.http != nil { return inspectHTTP(flow, now: now, output: &output) }
        switch HostSniffer.sniff(flow.clientBytes) {
        case .needMore:
            if flow.clientBytes.count >= HostSniffer.limit {
                finishSniffing(
                    flow, as: flow.clientBytes.first == 0x16 ? .tls(serverName: nil) : .unknown, now: now,
                    output: &output)
            }
        case let result:
            finishSniffing(flow, as: result, now: now, output: &output)
        }
    }

    func finishSniffing(_ flow: TrafficFlow, as result: HostSniffer.Result, now: Date, output: inout Output) {
        switch result {
        case .tls(let serverName):
            flow.application = .tls
            flow.serverName = serverName
            stopInspecting(flow)
        case .http:
            flow.application = .http
            flow.http = HTTPStream()
            inspectHTTP(flow, now: now, output: &output)
            return
        case .unknown, .needMore:
            flow.application = .other
            stopInspecting(flow)
        }

        decide(flow)
        report(flow, now: now, output: &output)
    }

    private enum HTTPStep {
        case next
        case wait
    }

    private func inspectHTTP(_ flow: TrafficFlow, now: Date, output: inout Output) {
        while flow.verdict == .allowed, flow.isInspecting, let http = flow.http, http.parsed < flow.clientBytes.count {
            let bytes = flow.clientBytes[http.parsed...]
            let step: HTTPStep
            switch http.body {
            case .head:
                step = readRequestHead(bytes, of: flow, now: now, output: &output)
            case .length(let remaining):
                step = skipBody(bytes, remaining: remaining, of: flow)
            case .chunkSize:
                step = readChunkSize(bytes, of: flow, now: now, output: &output)
            case .chunkData(let remaining):
                step = skipChunkData(bytes, remaining: remaining, of: flow)
            case .chunkEnd:
                step = readChunkEnd(bytes, of: flow, now: now, output: &output)
            case .trailers:
                step = readTrailers(bytes, of: flow, now: now, output: &output)
            case .tunnel:
                step = sniffTunnel(bytes, of: flow, now: now, output: &output)
            }
            guard step == .next else { return }
        }
    }

    private func readRequestHead(
        _ bytes: ArraySlice<UInt8>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> HTTPStep {
        guard let length = HostSniffer.headLength(bytes) else {
            if bytes.count > HostSniffer.maximumHead {
                stopOrFail(flow, "HTTP request head is too long", now: now, output: &output)
            }
            return .wait
        }
        guard let request = HostSniffer.request(bytes.prefix(length)) else {
            stopOrFail(flow, "not an HTTP request", now: now, output: &output)
            return .wait
        }
        guard accept(request, on: flow, now: now, output: &output) else { return .wait }

        flow.http?.parsed += length
        // After a WebSocket or h2c upgrade the bytes aren't HTTP/1; the Host was checked, like the SNI for TLS.
        if request.upgrades {
            stopInspecting(flow)
            return .wait
        }
        if request.method == "CONNECT" {
            guard policy.enforces else {
                stopInspecting(flow)
                return .wait
            }
            flow.http?.body = .tunnel
            return .next
        }
        if request.isChunked {
            flow.http?.body = .chunkSize
        } else if let remaining = request.contentLength, remaining > 0 {
            flow.http?.body = .length(remaining)
        }
        return .next
    }

    private func skipBody(_ bytes: ArraySlice<UInt8>, remaining: Int, of flow: TrafficFlow) -> HTTPStep {
        let take = min(remaining, bytes.count)
        flow.http?.parsed += take
        flow.http?.body = remaining == take ? .head : .length(remaining - take)
        return .next
    }

    private func readChunkSize(
        _ bytes: ArraySlice<UInt8>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> HTTPStep {
        guard let line = line(bytes) else {
            if bytes.count > Self.maximumLine { stopOrFail(flow, "bad HTTP chunk", now: now, output: &output) }
            return .wait
        }
        let text = String(decoding: bytes.prefix(line), as: UTF8.self)
        let sizeText = text.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let size = Int(sizeText, radix: 16), size >= 0 else {
            stopOrFail(flow, "bad HTTP chunk", now: now, output: &output)
            return .wait
        }

        flow.http?.parsed += line + 2
        flow.http?.body = size == 0 ? .trailers : .chunkData(size)
        return .next
    }

    private func skipChunkData(_ bytes: ArraySlice<UInt8>, remaining: Int, of flow: TrafficFlow) -> HTTPStep {
        let take = min(remaining, bytes.count)
        flow.http?.parsed += take
        flow.http?.body = remaining == take ? .chunkEnd : .chunkData(remaining - take)
        return .next
    }

    private func readChunkEnd(
        _ bytes: ArraySlice<UInt8>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> HTTPStep {
        guard bytes.count >= 2 else { return .wait }
        guard bytes[bytes.startIndex] == HostSniffer.carriageReturn, bytes[bytes.startIndex + 1] == HostSniffer.lineFeed
        else {
            stopOrFail(flow, "bad HTTP chunk", now: now, output: &output)
            return .wait
        }
        flow.http?.parsed += 2
        flow.http?.body = .chunkSize
        return .next
    }

    private func readTrailers(
        _ bytes: ArraySlice<UInt8>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> HTTPStep {
        guard let line = line(bytes) else {
            if bytes.count > Self.maximumLine { stopOrFail(flow, "bad HTTP chunk", now: now, output: &output) }
            return .wait
        }
        flow.http?.parsed += line + 2
        if line == 0 { flow.http?.body = .head }
        return .next
    }

    private func sniffTunnel(
        _ bytes: ArraySlice<UInt8>, of flow: TrafficFlow, now: Date, output: inout Output
    ) -> HTTPStep {
        switch HostSniffer.sniff(Array(bytes)) {
        case .needMore:
            if bytes.count >= HostSniffer.limit {
                finishSniffing(flow, as: .unknown, now: now, output: &output)
            }
            return .wait
        case .http:
            flow.http?.body = .head
            return .next
        case let result:
            finishSniffing(flow, as: result, now: now, output: &output)
            return .wait
        }
    }

    private func accept(_ request: HostSniffer.Request, on flow: TrafficFlow, now: Date, output: inout Output) -> Bool {
        flow.http?.requests += 1

        if flow.http?.requests == 1 {
            flow.serverName = request.host
            flow.method = request.method
            flow.path = request.path
            decide(flow)
            report(flow, now: now, output: &output)
            return flow.verdict == .allowed
        }

        var event = flow.event(.request, now: now)
        event.host = request.host ?? event.address
        event.method = request.method
        event.path = request.path
        event.reason = nil
        emit(event, now: now, output: &output)
        guard policy.enforces else { return true }

        let first = flow.serverName
        flow.serverName = request.host
        decide(flow)
        guard flow.verdict == .allowed else {
            flow.method = request.method
            flow.path = request.path
            report(flow, now: now, output: &output)
            return false
        }

        flow.serverName = first

        return true
    }

    private func line(_ bytes: ArraySlice<UInt8>) -> Int? {
        let end = bytes.startIndex + min(bytes.count, Self.maximumLine + 2)
        var index = bytes.startIndex
        while index + 1 < end {
            if bytes[index] == HostSniffer.carriageReturn, bytes[index + 1] == HostSniffer.lineFeed {
                return index - bytes.startIndex
            }
            index += 1
        }
        return nil
    }

    private func stopOrFail(_ flow: TrafficFlow, _ reason: String, now: Date, output: inout Output) {
        if policy.enforces {
            fail(flow, reason, now: now, output: &output)
        } else {
            stopInspecting(flow)
        }
    }

    func fail(_ flow: TrafficFlow, _ reason: String, now: Date, output: inout Output) {
        flow.verdict = .blocked
        flow.reason = reason
        stopInspecting(flow)
        report(flow, now: now, output: &output)
    }

    func stopInspecting(_ flow: TrafficFlow) {
        flow.isInspecting = false
        flow.http = nil
        flow.dns = nil
    }

    /// Checks each complete query in the buffer; one that is still arriving waits. A blocked query fails the flow,
    /// and the caller holds back the segment that completed it and resets the connection.
    private func inspectDNS(_ flow: TrafficFlow, now: Date, output: inout Output) {
        while flow.verdict == .allowed, let stream = flow.dns, flow.clientBytes.count - stream.parsed >= 2 {
            let length = Int(Packet.readUInt16(flow.clientBytes, at: stream.parsed))
            guard (12...Self.maximumDNSMessage).contains(length) else {
                return stopOrFail(flow, "not a DNS query", now: now, output: &output)
            }
            let start = stream.parsed + 2
            guard flow.clientBytes.count - start >= length else { return }
            guard let message = DNSMessage(Array(flow.clientBytes[start..<(start + length)])), !message.isResponse
            else {
                return stopOrFail(flow, "not a DNS query", now: now, output: &output)
            }
            flow.dns?.parsed = start + length
            guard checkQuery(message.question, over: flow, now: now, output: &output) else { return }
        }
    }

    private func checkQuery(
        _ question: DNSMessage.Question, over flow: TrafficFlow, now: Date, output: inout Output
    ) -> Bool {
        let (verdict, reason) =
            serviceRecordVerdict(question) ?? dnsVerdict(name: question.name, server: flow.key.remote)
        let query = PendingQuery(name: question.name, type: question.type, server: flow.key.remote, askedAt: now)
        var event = dnsEvent(query, answers: nil, reason: reason ?? "over TCP")
        event.verdict = verdict
        emit(event, now: now, output: &output)
        guard verdict == .allowed else {
            fail(flow, reason ?? "blocked", now: now, output: &output)
            return false
        }
        return true
    }
}
