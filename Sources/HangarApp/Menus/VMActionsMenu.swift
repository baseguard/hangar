import AppKit
import HangarKit
import SwiftUI

struct VMActionsMenu: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem
    var managesLibrary = false

    var body: some View {
        if !vm.isRunning {
            Section {
                Button("Start") { store.start(vm.name, then: showDisplay) }
                StartOptions(vm: vm, showDisplay: showDisplay)
            }
        } else {
            Section {
                VMConnectActions(vm: vm)
            }
            Section {
                if vm.phase == .paused {
                    Button("Resume") { store.resume(vm.name) }
                } else {
                    Button("Pause") { store.pause(vm.name) }
                }
                Button("Shut Down") { store.shutdown(vm.name) }
                if managesLibrary {
                    Button("Stop Now…") { VMDialog.stop(vm.name).post() }
                } else {
                    Button("Stop Now…") { confirmStop() }
                }
            }
        }
        VMManageActions(vm: vm, managesLibrary: managesLibrary)
    }

    private func showDisplay(_ name: String) {
        AppFocus.show { openWindow(id: DisplayWindow.id, value: name) }
    }

    private func confirmStop() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = ForceStop.title(vm.name)
        alert.informativeText = ForceStop.warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.forceStop(vm.name) }
    }
}
