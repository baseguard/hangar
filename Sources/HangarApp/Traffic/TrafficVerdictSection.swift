import HangarTraffic
import SwiftUI

struct TrafficVerdictSection: View {
    let verdict: TrafficEvent.Verdict
    let reason: String?

    var body: some View {
        Section {
            LabeledContent("Verdict") {
                Text(verdict == .blocked ? "Blocked" : "Allowed")
                    .foregroundStyle(verdict == .blocked ? Color.red : Color.secondary)
            }
            if let reason, !reason.isEmpty {
                LabeledContent("Reason") { Text(reason).textSelection(.enabled) }
            }
        }
    }
}
