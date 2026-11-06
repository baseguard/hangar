import SwiftUI

struct RunningControls: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let confirmStop: () -> Void

    var body: some View {
        if vm.phase == .paused {
            Button {
                store.resume(vm.name)
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .help("Resume")
        } else {
            Button {
                store.pause(vm.name)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help("Pause")
        }
        Menu {
            Button("Stop Now…", role: .destructive, action: confirmStop)
        } label: {
            Label("Shut Down", systemImage: "power")
        } primaryAction: {
            store.shutdown(vm.name)
        }
        .help("Ask the guest to shut down")
    }
}
