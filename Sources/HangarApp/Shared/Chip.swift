import SwiftUI

struct Chip<Content: View>: View {
    var systemImage: String?
    @ContentBuilder var content: Content

    var body: some View {
        HStack {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            content
        }
        .font(.callout)
        .padding(.horizontal, Metrics.controlInset)
        .frame(height: Metrics.controlSize)
        .background(.fill.tertiary, in: .capsule)
    }
}
