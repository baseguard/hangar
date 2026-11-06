import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI

struct ConnectionsTable: View {
    let vm: VMItem
    let rows: [TrafficConnection]
    @Binding var selection: Set<TrafficConnection.ID>
    let showDetails: () -> Void

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Connections Yet", systemImage: "arrow.up.arrow.down",
                description: Text("Connections to and from the VM appear here as they happen."))
        } else {
            ScrollsWhenNarrow {
                Table(rows, selection: $selection) {
                    TableColumn("Time") { row in TrafficTime(date: row.time) }
                        .width(.time)
                    TableColumn("Host") { row in ConnectionHostLabel(row: row) }
                        .width(.name)
                    TableColumn("Address") { row in Text(row.endpoint).monospaced().lineLimit(1) }
                        .width(.address)
                    TableColumn("Protocol") { row in Text(row.isRequest ? "HTTP" : row.proto.uppercased()) }
                        .width(.number)
                    TableColumn("Sent") { row in Text(row.sent.map(ByteSize.format) ?? "").monospacedDigit() }
                        .width(.number)
                    TableColumn("Received") { row in Text(row.received.map(ByteSize.format) ?? "").monospacedDigit() }
                        .width(.number)
                }
                .contextMenu(forSelectionType: TrafficConnection.ID.self) { ids in
                    TrafficRuleMenu(vm: vm, hosts: rows.filter { ids.contains($0.id) }.map(\.destination))
                } primaryAction: { _ in
                    showDetails()
                }
            }
        }
    }
}

private struct ConnectionHostLabel: View {
    let row: TrafficConnection

    var body: some View {
        Label {
            Text(row.destination).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(row.verdict == .blocked ? Color.red : Color.secondary)
        }
        .help(row.direction == "in" ? "Incoming connection" : "Outgoing connection")
        .accessibilityLabel(
            "\(row.verdict == .blocked ? "Blocked" : row.direction == "in" ? "Incoming" : "Outgoing"): \(row.destination)"
        )
    }

    private var symbol: String {
        if row.verdict == .blocked { return "xmark.octagon.fill" }
        if row.isRequest { return "arrow.turn.down.right" }
        return row.direction == "in" ? "arrow.down.left" : "arrow.up.right"
    }
}
