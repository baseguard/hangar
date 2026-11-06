import SwiftUI

extension View {
    func minimumHitArea() -> some View {
        frame(minWidth: Metrics.smallControlSize, minHeight: Metrics.smallControlSize).contentShape(.rect)
    }
}
