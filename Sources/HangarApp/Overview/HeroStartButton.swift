import SwiftUI

struct HeroStartButton: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.start(vm.name) { openWindow(id: DisplayWindow.id, value: $0) }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .padding(.leading, Metrics.controlInset)
                    .padding(.trailing, Metrics.spacing)
                    .frame(height: Metrics.controlSize)
                    .contentShape(.rect)
            }
            .buttonStyle(PressDarkens())
            .help("Start in a window")
            Rectangle()
                .fill(.white.opacity(Metrics.dividerOnTint))
                .frame(width: Metrics.hairline)
                .padding(.vertical, Metrics.spacing)
            StartOptionsMenu(vm: vm)
        }
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
        .foregroundStyle(.white)
        .frame(height: Metrics.controlSize)
        .background(Color.accentColor)
        .clipShape(.capsule)
        .fixedSize()
        .disabled(store.busy.contains(vm.name))
        .opacity(store.busy.contains(vm.name) ? Metrics.disabledOpacity : 1)
    }
}

private struct StartOptionsMenu: View {
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem

    var body: some View {
        Menu {
            StartOptions(vm: vm) { openWindow(id: DisplayWindow.id, value: $0) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.leading, Metrics.spacing)
                .padding(.trailing, Metrics.controlInset)
                .frame(height: Metrics.controlSize)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More ways to start")
    }
}

private struct PressDarkens: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.black.opacity(configuration.isPressed ? Metrics.pressedDim : 0))
    }
}
