import AppKit
import SwiftUI

struct WelcomeView: View {
    let create: (CreateVMView.Kind) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.openSpacing) {
                VStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: Metrics.appIconSize, height: Metrics.appIconSize)
                        .accessibilityHidden(true)
                    Text("Welcome to Hangar")
                        .font(.largeTitle.weight(.bold))
                    Text("Run macOS, Linux and Windows on this Mac, and see where their traffic goes.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                KindGrid(pick: create)
                    .frame(maxWidth: CreateVMView.width)
            }
            .scenePadding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Welcome")
    }
}
