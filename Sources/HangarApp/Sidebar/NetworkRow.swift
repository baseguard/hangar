import SwiftUI

struct NetworkRow: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        Label {
            HStack {
                Text("Network")
                Spacer()
                if store.network != nil {
                    Circle()
                        .fill(.green)
                        .frame(width: Metrics.indicatorSize, height: Metrics.indicatorSize)
                        .help("Running")
                        .accessibilityLabel("Running")
                }
            }
        } icon: {
            Image(systemName: "network")
        }
    }
}
