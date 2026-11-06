import HangarKit
import SwiftUI

struct ImageAccountSection: View {
    let footer: LocalizedStringKey

    var body: some View {
        Section {
            LabeledContent("User name", value: MacImage.user)
            LabeledContent("Password", value: MacImage.password)
        } header: {
            Text("Account")
        } footer: {
            Text(footer)
        }
    }
}
