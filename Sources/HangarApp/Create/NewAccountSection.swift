import SwiftUI

struct NewAccountSection: View {
    @Binding var createAccount: Bool
    @Binding var username: String
    @Binding var password: String
    let footer: LocalizedStringKey

    var body: some View {
        Section {
            Toggle("Create an account on the first start", isOn: $createAccount)
            if createAccount {
                TextField("User name", text: $username)
                SecureField("Password", text: $password)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(footer)
        }
    }
}
