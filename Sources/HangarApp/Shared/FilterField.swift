import SwiftUI

struct FilterField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Metrics.regularControlInset)
        .frame(height: Metrics.regularControlSize)
        .background(.fill.tertiary, in: .capsule)
        .onKeyPress(.escape) {
            guard !text.isEmpty else { return .ignored }
            text = ""
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isSearchField)
    }
}
