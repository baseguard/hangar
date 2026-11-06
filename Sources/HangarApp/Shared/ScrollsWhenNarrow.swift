import SwiftUI

struct ScrollsWhenNarrow<Content: View>: View {
    @ContentBuilder var content: Content
    @State private var visibleWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            AtLeastWidth(width: visibleWidth) { content }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            visibleWidth = $0
        }
    }
}

// Without a horizontal scroll view around it, a SwiftUI table never gets narrower than its columns' minimum widths
// and pushes the page wider instead; inside one it takes the visible width and scrolls its columns.
private struct AtLeastWidth: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fitting = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
        return CGSize(width: max(fitting.width, width), height: proposal.height ?? fitting.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
