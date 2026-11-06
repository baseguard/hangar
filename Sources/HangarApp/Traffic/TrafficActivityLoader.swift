import HangarKit
import HangarTraffic
import SwiftUI

private struct TrafficActivityLoader: ViewModifier {
    private static let pollInterval = Duration.seconds(1.5)
    let bundle: VMBundle
    @Binding var activity: TrafficActivity
    @State private var stamp = ""

    func body(content: Content) -> some View {
        content.task(id: bundle.name) {
            while !Task.isCancelled {
                let current = await runInBackground { [bundle] in TrafficLog.stamp(of: bundle.trafficLogURL) }
                if current != stamp {
                    stamp = current
                    activity = await TrafficActivity.load(from: bundle)
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}

extension View {
    func trafficActivity(of bundle: VMBundle, into activity: Binding<TrafficActivity>) -> some View {
        modifier(TrafficActivityLoader(bundle: bundle, activity: activity))
    }
}
