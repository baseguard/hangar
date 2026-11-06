import HangarKit
import HangarTraffic
import SwiftUI

struct TrafficDetailsPanel: View {
    let vm: VMItem
    let model: DetailModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.trafficScope == .lookups ? "DNS Lookup" : "Connection")
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Close")
            }
            .scenePadding(.horizontal)
            .padding(.vertical, Metrics.spacing)
            Divider()
            content
                .frame(maxHeight: .infinity)
        }
    }

    @ContentBuilder
    private var content: some View {
        switch model.trafficScope {
        case .connections:
            if let row = selected(model.connectionSelection, in: model.activity.connections) {
                ConnectionDetails(vm: vm, row: row)
            } else {
                noSelection(model.connectionSelection.count)
            }
        case .lookups:
            if let row = selected(model.lookupSelection, in: model.activity.lookups) {
                LookupDetails(vm: vm, row: row)
            } else {
                noSelection(model.lookupSelection.count)
            }
        case .hosts, .rules:
            EmptyView()
        }
    }

    private func close() {
        model.showsTrafficDetails = false
        model.connectionSelection = []
        model.lookupSelection = []
    }

    private func selected<Row: Identifiable>(_ ids: Set<Row.ID>, in rows: [Row]) -> Row? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    private func noSelection(_ count: Int) -> some View {
        ContentUnavailableView(
            count > 1 ? "\(count) Rows Selected" : "No Selection", systemImage: "sidebar.trailing",
            description: Text("Select one row to see its details."))
    }
}
