import HangarKit
import HangarTraffic
import SwiftUI

struct LookupsTable: View {
    let vm: VMItem
    let rows: [TrafficLookup]
    @Binding var selection: Set<TrafficLookup.ID>
    let showDetails: () -> Void

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Lookups Yet", systemImage: "magnifyingglass",
                description: Text("The names the VM looks up in DNS appear here."))
        } else {
            ScrollsWhenNarrow {
                Table(rows, selection: $selection) {
                    TableColumn("Time") { row in TrafficTime(date: row.event.time) }
                        .width(.time)
                    TableColumn("Name") { row in
                        Text(row.event.query ?? "").lineLimit(1)
                            .foregroundStyle(row.isBlocked ? Color.red : Color.primary)
                    }
                    .width(.name)
                    TableColumn("Type") { row in Text(row.event.queryType ?? "") }
                        .width(.number)
                    TableColumn("Answer") { row in
                        let answer = Self.answerText(for: row)
                        Text(answer)
                            .lineLimit(1)
                            .foregroundStyle(row.isBlocked ? Color.red : Color.secondary)
                            .help(answer)
                    }
                }
                .contextMenu(forSelectionType: TrafficLookup.ID.self) { ids in
                    TrafficRuleMenu(vm: vm, hosts: rows.filter { ids.contains($0.id) }.compactMap(\.event.query))
                } primaryAction: { _ in
                    showDetails()
                }
            }
        }
    }

    /// A blocked lookup shows why; an answered one its addresses and aliases, then any error.
    private static func answerText(for row: TrafficLookup) -> String {
        if row.isBlocked { return row.event.reason ?? "Blocked" }
        let parts = [row.event.answers?.joined(separator: ", "), row.event.reason]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
