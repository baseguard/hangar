import SwiftUI

struct LegendMark: View {
    let title: String
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: Metrics.indicatorSize, height: Metrics.indicatorSize)
            Text(title)
        }
    }
}
