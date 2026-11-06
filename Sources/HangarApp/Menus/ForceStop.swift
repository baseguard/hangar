import SwiftUI

enum ForceStop {
    static func title(_ name: String) -> String { "Stop “\(name)” now?" }
    static let warning = "This turns the VM off at once, like pulling the plug. Unsaved work in the guest is lost."
}

/// The confirmation in Hangar's windows; the menu bar menu has no window to attach it to and uses an alert.
struct ForceStopConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var stopping: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            ForceStop.title(stopping ?? ""), isPresented: isPresented($stopping), titleVisibility: .visible
        ) {
            Button("Stop") {
                if let stopping { store.forceStop(stopping) }
            }
        } message: {
            Text(ForceStop.warning)
        }
    }
}
