import Foundation
import SwiftUI

struct TrafficTime: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.hour().minute().second())
            .monospacedDigit()
            .help(date.formatted(date: .abbreviated, time: .standard))
    }
}
