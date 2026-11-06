import HangarKit
import SwiftUI

struct ScreenPreview: View {
    static let aspectRatio = CGFloat(DisplaySettings.linuxDefault.width) / CGFloat(DisplaySettings.linuxDefault.height)

    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(DetailModel.self) private var detail: DetailModel?
    let vm: VMItem

    var body: some View {
        let display = vm.config.guestDisplay
        ZStack {
            if let session = store.sessions[vm.name], vm.isRunning, detail.map({ $0.page == .overview }) ?? true {
                LiveScreen(virtualMachine: session.virtualMachine)
                    .aspectRatio(CGFloat(display.width) / CGFloat(max(display.height, 1)), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .allowsHitTesting(false)
            } else {
                Rectangle()
                    .fill(vm.config.os.tint.gradient)
                    .overlay {
                        VStack(spacing: Metrics.spacing) {
                            Image(systemName: vm.config.os.symbolName)
                                .font(.system(size: Metrics.iconSize, weight: .semibold))
                                .foregroundStyle(.white.opacity(Metrics.iconOnDark))
                            Text(caption)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, Metrics.controlInset)
                                .frame(height: Metrics.controlSize)
                                .background(.black.opacity(Metrics.captionOnDark), in: .capsule)
                        }
                    }
            }
            Button("Show Display", systemImage: "arrow.up.left.and.arrow.down.right", action: showDisplay)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Show the display of \(vm.name)")
                .padding(Metrics.bezelSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous).strokeBorder(.separator))
    }

    private func showDisplay() {
        openWindow(id: DisplayWindow.id, value: vm.name)
    }

    private var caption: String {
        switch vm.phase {
        case .stopped, .failed: "Not running"
        case .running, .paused: "Running without a window"
        case .busy(let state): state
        }
    }
}
