import HangarKit
import HangarTraffic
import SwiftUI

struct LookupDetails: View {
    let vm: VMItem
    let row: TrafficLookup

    var body: some View {
        let event = row.event
        Form {
            Section {
                LabeledContent("Name") { Text(event.query ?? "").textSelection(.enabled) }
                LabeledContent("Type", value: event.queryType ?? "")
                LabeledContent("DNS Server") { Text(event.address ?? "").monospaced().textSelection(.enabled) }
                LabeledContent("Time", value: event.time.formatted(date: .abbreviated, time: .standard))
            }
            Section("Answers") {
                let answers = event.answers ?? []
                if answers.isEmpty {
                    Text("No answers").foregroundStyle(.secondary)
                }
                ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                    Text(answer).monospaced().textSelection(.enabled)
                }
            }
            TrafficVerdictSection(verdict: event.verdict ?? .allowed, reason: event.reason)
            if let query = event.query {
                TrafficRuleSection(vm: vm, host: query)
            }
        }
        .formStyle(.grouped)
    }
}
