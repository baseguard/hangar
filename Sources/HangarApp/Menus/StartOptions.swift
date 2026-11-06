import HangarKit
import SwiftUI

struct StartOptions: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let showDisplay: (String) -> Void

    var body: some View {
        Button("Start in Background") { store.startInBackground(vm.name) }
        if vm.config.os == .macOS {
            Button("Start in Recovery") { store.start(vm.name, recovery: true, then: showDisplay) }
        }
    }
}
