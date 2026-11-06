import SwiftUI

struct CardGrid: Layout {
    var minColumnWidth: CGFloat
    var maxColumns: Int
    var spacing: CGFloat

    private func arrange(_ width: CGFloat?, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let available = max(
            width ?? minColumnWidth * CGFloat(maxColumns) + spacing * CGFloat(maxColumns - 1), minColumnWidth)
        let count = max(1, min(maxColumns, subviews.count, Int((available + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: count) {
            let row = subviews[start..<min(start + count, subviews.count)]
            let height =
                row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
            for (column, _) in row.enumerated() {
                frames.append(
                    CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            }
            y += height + spacing
        }
        return (frames, CGSize(width: available, height: max(0, y - spacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
