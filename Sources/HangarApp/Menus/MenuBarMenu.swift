import AppKit
import HangarKit
import HangarSupport
import SwiftUI

struct MenuBarMenu: View {
    static let visibilityKey = "showMenuBarItem"

    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let running = store.vms.filter(\.isRunning).count
        Text(running == 0 ? "No VMs running" : "\(running) of \(store.vms.count) VMs running")
        Divider()
        ForEach(store.vms) { vm in
            Menu {
                VMActionsMenu(vm: vm)
            } label: {
                Label(title(vm), systemImage: vm.config.os.symbolName)
            }
        }
        if !store.vms.isEmpty {
            Divider()
        }
        Button("Open Hangar") {
            AppFocus.show { openWindow(id: MainWindow.id) }
        }
        Button("Settings…") {
            AppFocus.show { openSettings() }
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Hangar") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(_ vm: VMItem) -> String {
        guard vm.phase == .running, let usage = store.usage[vm.name] else {
            return "\(vm.name) — \(vm.phase.title.lowercased())"
        }
        var parts: [String] = []
        if let cpu = usage.cpuText(of: vm.config.cpuCount) { parts.append(cpu) }
        parts.append(ByteSize.format(usage.memoryInUse))
        return "\(vm.name) — " + parts.joined(separator: " · ")
    }
}
