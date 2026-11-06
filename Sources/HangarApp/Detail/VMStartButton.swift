import SwiftUI

struct VMStartButton: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem

    var body: some View {
        Menu {
            StartOptions(vm: vm) { openWindow(id: DisplayWindow.id, value: $0) }
        } label: {
            Label("Start", systemImage: "play.fill")
        } primaryAction: {
            store.start(vm.name) { openWindow(id: DisplayWindow.id, value: $0) }
        }
        .disabled(store.busy.contains(vm.name))
        .help("Start in a window")
    }
}
