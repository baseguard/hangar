import SwiftUI

struct AccessoryRow: Layout {
    var minPrimaryWidth: CGFloat
    var spacing: CGFloat

    private func stacks(_ width: CGFloat?, accessory: CGSize) -> Bool {
        guard let width else { return false }
        return width - accessory.width - spacing < minPrimaryWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let accessory = subviews[1].sizeThatFits(.unspecified)
        if stacks(proposal.width, accessory: accessory) {
            let primary = subviews[0].sizeThatFits(
                ProposedViewSize(width: max(proposal.width ?? 0, minPrimaryWidth), height: nil))
            return CGSize(
                width: max(proposal.width ?? 0, accessory.width), height: primary.height + spacing + accessory.height)
        }

        let primaryWidth = proposal.width.map { $0 - accessory.width - spacing }
        let primary = subviews[0].sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))
        return CGSize(
            width: proposal.width ?? primary.width + spacing + accessory.width,
            height: max(primary.height, accessory.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let accessory = subviews[1].sizeThatFits(.unspecified)
        if stacks(bounds.width, accessory: accessory) {
            let primary = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: primary.height))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + primary.height + spacing),
                proposal: ProposedViewSize(accessory))
        } else {
            let primaryWidth = bounds.width - accessory.width - spacing
            let primary = subviews[0].sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: primaryWidth, height: primary.height))
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(accessory))
        }
    }
}
