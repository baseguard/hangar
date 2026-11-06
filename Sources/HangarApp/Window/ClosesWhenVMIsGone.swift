import SwiftUI

/// Closes a VM's own window, its display or its files, once the VM is renamed in Hangar or has left the library, such
/// as after `hangar delete`, a rename in Terminal or its folder being removed.
struct ClosesWhenVMIsGone: ViewModifier {
    @Environment(VMStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    let name: String
    let windowID: String

    func body(content: Content) -> some View {
        content
            .onMessage(VirtualMachineRenamedMessage.self) { message in
                if message.oldName == name { close() }
            }
            // Only a change closes it: a new VM's display opens before the library scan lists it.
            .onChange(of: isGone) { _, isGone in
                if isGone { close() }
            }
    }

    /// Before the first scan the library is still empty, not without this VM.
    private var isGone: Bool {
        store.hasScanned && store.vm(name) == nil
    }

    private func close() {
        dismissWindow(id: windowID, value: name)
    }
}
