import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct ConnectionDetails: View {
    let vm: VMItem
    let row: TrafficConnection

    var body: some View {
        Form {
            Section {
                LabeledContent("Host") { Text(row.destination).textSelection(.enabled) }
                LabeledContent("Address") { Text(row.endpoint).monospaced().textSelection(.enabled) }
                LabeledContent("Direction", value: row.direction == "in" ? "Incoming" : "Outgoing")
                LabeledContent("Protocol", value: row.isRequest ? "HTTP" : row.proto.uppercased())
                if let method = row.method {
                    LabeledContent("Request") { Text("\(method) \(row.path ?? "")").textSelection(.enabled) }
                }
            }
            Section {
                LabeledContent("Started", value: row.time.formatted(date: .abbreviated, time: .standard))
                if let duration = row.duration {
                    LabeledContent("Duration", value: String(format: "%.1f s", duration))
                } else if row.isOpen {
                    LabeledContent("Duration", value: "Open")
                }
                if let sent = row.sent { LabeledContent("Sent", value: ByteSize.format(sent)) }
                if let received = row.received { LabeledContent("Received", value: ByteSize.format(received)) }
            }
            TrafficVerdictSection(verdict: row.verdict, reason: row.reason)
            TrafficRuleSection(vm: vm, host: row.destination)
        }
        .formStyle(.grouped)
    }
}
