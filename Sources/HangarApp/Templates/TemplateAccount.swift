import HangarKit
import SwiftUI

/// The account a VM made from a template needs, by what it is made from: Hangar's agent comes with the account, so
/// without one the setup commands never run.
enum TemplateAccountKind {
    /// A Linux installer ISO, or an image with its own accounts.
    case none
    /// Hangar's ready images: admin, password admin.
    case hangarImage
    case linux
    case mac
    case windows

    init(template: VMTemplate, origin: VMTemplate.Origin?) {
        guard let origin else {
            self = .none
            return
        }

        if origin.cloudImage != nil {
            self = .hangarImage
        } else if let macImage = template.macImage(in: origin) {
            self = macImage == "vanilla" ? .mac : .hangarImage
        } else if origin.image != nil {
            self = .none
        } else if origin.diskImage != nil {
            self = .linux
        } else if origin.ipsw != nil {
            self = .mac
        } else {
            self = template.os == .windows ? .windows : .none
        }
    }
}

struct TemplateAccountSection: View {
    let kind: TemplateAccountKind
    @Binding var fields: AccountFields

    var body: some View {
        switch kind {
        case .none:
            EmptyView()
        case .hangarImage:
            ImageAccountSection(
                footer:
                    "Hangar's image comes with this administrator. Anyone who can reach the VM can sign in with this password, so change it in the VM."
            )
        case .linux:
            NewAccountSection(
                createAccount: $fields.createAccount, username: $fields.username, password: $fields.password,
                footer:
                    "Cloud-init creates this account with administrator rights, and Hangar's agent comes with it; without them the setup commands don't run."
            )
        case .mac:
            MacAccountSection(
                createAccount: $fields.createAccount, username: $fields.username, fullName: $fields.fullName,
                password: $fields.password, autoLogin: $fields.autoLogin, remoteLogin: $fields.remoteLogin)
        case .windows:
            WindowsAccountSection(
                username: $fields.username, password: $fields.password, remoteDesktop: $fields.remoteDesktop)
        }
    }
}
