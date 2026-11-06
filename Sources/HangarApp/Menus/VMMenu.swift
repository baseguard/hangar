import SwiftUI

struct VMMenu: Commands {
    let store: VMStore

    var body: some Commands {
        CommandMenu("Virtual Machine") { FrontVMCommands().environment(store) }
    }
}

/// The menu bar's Virtual Machine menu acts on the VM of the window in front.
private struct FrontVMCommands: View {
    @FocusedValue(\.selectedVM) private var name

    var body: some View {
        VMCommands(name: name)
    }
}
