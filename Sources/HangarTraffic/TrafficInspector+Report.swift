import Foundation
import HangarPackets
import HangarSupport

/// What the inspector tells the log: each flow's events, with a cap per second so a flood of connections
/// doesn't flood the log too.
extension TrafficInspector {
    func report(_ flow: TrafficFlow, now: Date, output: inout Output) {
        if flow.isQuiet, flow.verdict == .allowed { return }
        flow.isQuiet = false
        if !flow.wasAnnounced {
            flow.wasAnnounced = true
            emit(flow.event(.connect, now: now), now: now, output: &output)
        } else if flow.verdict == .blocked {
            emit(flow.event(.block, now: now), now: now, output: &output)
        }
    }

    func close(_ flow: TrafficFlow, now: Date, output: inout Output) {
        release(flow)
        forgetDiversion(of: flow)
        if flow.isQuiet { return }
        if !flow.wasAnnounced {
            flow.wasAnnounced = true
            emit(flow.event(.connect, now: flow.startedAt), now: now, output: &output)
        }
        if flow.verdict == .allowed || flow.isBlockedAfterClosing || flow.sent + flow.received > 0 {
            emit(flow.event(.close, now: flow.lastSeen), now: now, output: &output)
        }
    }

    func release(_ flow: TrafficFlow) {
        bufferedBytes -= flow.clientBytes.count
        flow.clientBytes = []
        stopInspecting(flow)
    }

    func emit(_ event: TrafficEvent, now: Date, output: inout Output) {
        flushSuppressed(now: now, output: &output)
        guard eventsInWindow < Self.maximumEventsPerSecond else {
            suppressedEvents += 1
            return
        }
        eventsInWindow += 1
        output.events.append(event)
    }

    func flushSuppressed(now: Date, output: inout Output) {
        guard now.timeIntervalSince(eventWindow) >= 1 else { return }
        if suppressedEvents > 0 {
            output.events.append(
                TrafficEvent(
                    time: now, kind: .notice,
                    reason:
                        "\(suppressedEvents) more events were not recorded (over \(Self.maximumEventsPerSecond) a second)"
                ))
        }
        eventWindow = now
        eventsInWindow = 0
        suppressedEvents = 0
    }

    /// `protocolNumber` says what was dropped when it was an IP packet.
    func reportSpoof(_ what: String, protocolNumber: UInt8? = nil, now: Date, output: inout Output) {
        guard now.timeIntervalSince(lastSpoofReport) > Self.spoofReportInterval else { return }
        lastSpoofReport = now
        let proto = protocolNumber.map(TrafficFlow.protocolName)
        emit(
            TrafficEvent(time: now, kind: .block, proto: proto, verdict: .blocked, reason: "dropped \(what)"),
            now: now, output: &output)
    }
}
