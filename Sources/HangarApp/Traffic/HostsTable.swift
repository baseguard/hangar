import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct HostsTable: View {
    let vm: VMItem
    let rows: [TrafficHost]
    @State private var selection = Set<TrafficHost.ID>()

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Hosts Yet", systemImage: "globe",
                description: Text("Every host the VM looks up or connects to is listed here."))
        } else {
            ScrollsWhenNarrow {
                let rules = TrafficRules(vm.config.traffic)
                Table(rows, selection: $selection) {
                    TableColumn("Host") { row in
                        HStack {
                            Text(row.name).lineLimit(1)
                            if let verdict = rules.verdict(for: row.name) {
                                Text(verdict.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(verdict == .blocked ? Color.red : Color.green)
                            }
                        }
                    }
                    .width(.name)
                    TableColumn("Connections") { row in Text("\(row.connections)").monospacedDigit() }
                        .width(.wideNumber)
                    TableColumn("Lookups") { row in Text("\(row.lookups)").monospacedDigit() }
                        .width(.number)
                    TableColumn("Blocked") { row in
                        Text(row.blocked == 0 ? "" : "\(row.blocked)").monospacedDigit().foregroundStyle(.red)
                    }
                    .width(.number)
                    TableColumn("Sent") { row in Text(ByteSize.format(row.sent)).monospacedDigit() }
                        .width(.number)
                    TableColumn("Received") { row in Text(ByteSize.format(row.received)).monospacedDigit() }
                        .width(.number)
                    TableColumn("Last Seen") { row in TrafficTime(date: row.lastSeen) }
                        .width(.time)
                }
                .contextMenu(forSelectionType: TrafficHost.ID.self) { ids in
                    TrafficRuleMenu(vm: vm, hosts: Array(ids))
                }
            }
        }
    }
}
