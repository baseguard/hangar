import HangarKit
import SwiftUI

/// An agent update that waits for the guest password of the account signed in to the VM.
struct AgentPasswordRequest: Identifiable {
    let vm: String
    let wasWrong: Bool

    var id: String { vm }
}

/// Asks for the guest password and runs the update again with it. The field is emptied on either button, so the
/// password stays only with the update it was given to.
struct AgentPasswordAlert: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var request: AgentPasswordRequest?
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented($request)) {
            SecureField("Password", text: $password)
            Button("Update") {
                if let request { store.updateAgent(request.vm, password: password) }
                password = ""
            }
            .disabled(password.isEmpty)
            Button("Cancel", role: .cancel) { password = "" }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        guard let request else { return "" }
        return "Password for “\(request.vm)”"
    }

    private var message: String {
        if request?.wasWrong == true { return "That password didn't work. Try again." }
        return "Updating Hangar's agent needs the password of the account signed in to the VM. Hangar doesn't keep it."
    }
}
