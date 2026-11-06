import SwiftUI

struct TrailingRow: Layout {
    var spacing: CGFloat
    var trailingWidth: ClosedRange<CGFloat>

    private func arrange(_ width: CGFloat?, _ subviews: Subviews) -> (
        leading: [CGSize], trailing: CGSize, wraps: Bool, width: CGFloat
    ) {
        let leading = subviews.dropLast().map { $0.sizeThatFits(.unspecified) }
        let leadingWidth = leading.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, leading.count - 1))
        let trailingHeight =
            subviews.last?.sizeThatFits(ProposedViewSize(width: trailingWidth.upperBound, height: nil)).height ?? 0
        let available = width ?? leadingWidth + spacing * 2 + trailingWidth.upperBound
        let room = available - leadingWidth - spacing * 2
        if room >= trailingWidth.lowerBound {
            return (
                leading, CGSize(width: min(room, trailingWidth.upperBound), height: trailingHeight), false,
                max(available, leadingWidth)
            )
        }
        return (
            leading,
            CGSize(
                width: min(max(available, trailingWidth.lowerBound), trailingWidth.upperBound), height: trailingHeight),
            true, max(leadingWidth, trailingWidth.lowerBound)
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let layout = arrange(proposal.width, subviews)
        let leadingHeight = layout.leading.map(\.height).max() ?? 0
        let height =
            layout.wraps ? leadingHeight + spacing + layout.trailing.height : max(leadingHeight, layout.trailing.height)
        return CGSize(width: max(layout.width, proposal.width ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let last = subviews.last else { return }
        let layout = arrange(bounds.width, subviews)
        let leadingHeight = layout.leading.map(\.height).max() ?? 0
        let rowHeight = layout.wraps ? leadingHeight : max(leadingHeight, layout.trailing.height)
        var x = bounds.minX
        for (index, size) in layout.leading.enumerated() {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY + rowHeight / 2), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }

        let trailingProposal = ProposedViewSize(width: layout.trailing.width, height: layout.trailing.height)
        if layout.wraps {
            last.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + leadingHeight + spacing), proposal: trailingProposal)
        } else {
            last.place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + rowHeight / 2), anchor: .trailing,
                proposal: trailingProposal)
        }
    }
}
