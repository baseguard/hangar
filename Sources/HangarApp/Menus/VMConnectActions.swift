import HangarKit
import SwiftUI

struct VMConnectActions: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem

    var body: some View {
        if store.sessions[vm.name] != nil {
            Button("Show Display") { AppFocus.show { openWindow(id: DisplayWindow.id, value: vm.name) } }
        }
        if vm.isRunning {
            Button("Browse Files…") { AppFocus.show { openWindow(id: FilesWindow.id, value: vm.name) } }
        }
        if let ip = vm.ip {
            if vm.config.os == .windows {
                Button("Remote Desktop") { store.openRemoteDesktop(vm.name) }
                    .disabled(!vm.config.remoteDesktop)
            } else {
                Button("Open in Terminal") { store.openSSH(vm.name) }
            }
            Button("Copy IP Address (\(ip))") { Pasteboard.copy(ip) }
        }
    }
}
