import SwiftUI

struct HeroLayout: Layout {
    var previewWidth: CGFloat
    var spacing: CGFloat
    var minInfoWidth: CGFloat = 320
    var minStackedWidth: CGFloat = 240
    var maxStackedPreviewWidth: CGFloat = 440

    private func sideBySide(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= previewWidth + spacing + minInfoWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let preview = subviews[0]
        let info = subviews[1]
        if sideBySide(proposal.width) {
            let infoWidth = proposal.width.map { $0 - previewWidth - spacing }
            let infoSize = info.sizeThatFits(ProposedViewSize(width: infoWidth, height: nil))
            let previewSize = preview.sizeThatFits(ProposedViewSize(width: previewWidth, height: nil))
            return CGSize(
                width: proposal.width ?? previewWidth + spacing + infoSize.width,
                height: max(previewSize.height, infoSize.height))
        }

        let width = max(proposal.width ?? 0, minStackedWidth)
        let infoSize = info.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let previewSize = preview.sizeThatFits(ProposedViewSize(width: min(width, maxStackedPreviewWidth), height: nil))
        return CGSize(width: max(width, infoSize.width), height: previewSize.height + spacing + infoSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let preview = subviews[0]
        let info = subviews[1]
        if sideBySide(bounds.width) {
            let infoProposal = ProposedViewSize(width: bounds.width - previewWidth - spacing, height: nil)
            let previewHeight = preview.sizeThatFits(ProposedViewSize(width: previewWidth, height: nil)).height
            let infoHeight = info.sizeThatFits(infoProposal).height
            preview.place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: previewWidth, height: previewHeight))
            info.place(
                at: CGPoint(x: bounds.minX + previewWidth + spacing, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: infoProposal.width, height: infoHeight))
        } else {
            let previewProposal = ProposedViewSize(width: min(bounds.width, maxStackedPreviewWidth), height: nil)
            let previewHeight = preview.sizeThatFits(previewProposal).height
            preview.place(at: bounds.origin, proposal: previewProposal)
            info.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + previewHeight + spacing),
                proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
