import SwiftUI

struct KindPicker: View {
    let close: () -> Void
    let openTemplate: () -> Void
    let pick: (CreateVMView.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.openSpacing) {
            VStack(alignment: .leading) {
                Text("New Virtual Machine").font(.title2.weight(.semibold))
                Text("Choose what to run.").foregroundStyle(.secondary)
            }
            KindGrid(pick: pick)
            HStack {
                Button("Open Template…", action: openTemplate)
                    .help("Make a VM from a .hangarvm file")
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .scenePadding()
    }
}
