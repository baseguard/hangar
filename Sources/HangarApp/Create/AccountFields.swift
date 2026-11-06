import HangarKit

/// What the user typed for the account; only the fields of the asked kind are used.
struct AccountFields {
    var createAccount = true
    var username = "admin"
    var fullName = ""
    var password = ""
    var autoLogin = true
    var remoteLogin = true
    var remoteDesktop = true

    var linux: CloudInitAccount? {
        createAccount ? CloudInitAccount(username: username, password: password) : nil
    }

    var mac: MacProvisioning? {
        guard createAccount else { return nil }
        return MacProvisioning(
            fullName: fullName.isEmpty ? username : fullName, username: username, password: password,
            autoLogin: autoLogin, remoteLogin: remoteLogin)
    }

    var windows: WindowsInstaller.Account {
        WindowsInstaller.Account(username: username, password: password, remoteDesktop: remoteDesktop)
    }
}
