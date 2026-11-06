import SwiftUI

/// A copy icon that turns into a green checkmark for a moment after a copy. Both images stay in the
/// layout, so the swap doesn't move or resize anything.
struct CopyButton: View {
    /// How long the checkmark stays after a copy.
    private static let copiedHint = Duration.seconds(1.5)
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
        } label: {
            ZStack {
                Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1)
                Image(systemName: "checkmark").opacity(copied ? 1 : 0)
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .minimumHitArea()
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy \(text)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: Self.copiedHint)
            copied = false
        }
    }
}
