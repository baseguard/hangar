import AppKit
import HangarKit
import HangarSupport
import SwiftUI
import UniformTypeIdentifiers

struct NetworkChoiceSection: View {
    @Binding var network: NetworkMode

    var body: some View {
        Section {
            Picker("Network", selection: $network) {
                ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } footer: {
            Text(hint)
        }
    }

    private var hint: String {
        switch network {
        case .managed:
            "NAT through Hangar's network: allow and block lists, isolation, a stable address, and VMs can reach each other."
        case .nat: "The system's NAT: internet and this Mac, no traffic rules, and VMs can't reach each other."
        case .none: "No network adapter."
        }
    }
}

struct FileRow: View {
    let path: String
    let choose: () -> Void

    var body: some View {
        LabeledContent("File") {
            HStack {
                Text(path.isEmpty ? "None" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: choose)
            }
        }
    }
}

struct MacAccountSection: View {
    @Binding var createAccount: Bool
    @Binding var username: String
    @Binding var fullName: String
    @Binding var password: String
    @Binding var autoLogin: Bool
    @Binding var remoteLogin: Bool

    var body: some View {
        Section {
            Toggle("Create an account on the first start", isOn: $createAccount)
            if createAccount {
                TextField("User name", text: $username)
                TextField("Full name", text: $fullName, prompt: Text(username.isEmpty ? "Administrator" : username))
                SecureField("Password", text: $password)
                Toggle("Log in automatically", isOn: $autoLogin)
                Toggle("Turn on Remote Login (SSH)", isOn: $remoteLogin)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Skips Setup Assistant on macOS 27 and later. Otherwise set the Mac up in its window.")
        }
    }
}

struct WindowsAccountSection: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var remoteDesktop: Bool

    var body: some View {
        Section {
            TextField("User name", text: $username)
            SecureField("Password", text: $password)
            Toggle("Turn on Remote Desktop", isOn: $remoteDesktop)
        } header: {
            Text("Account")
        } footer: {
            Text(
                "Remote Desktop works at any screen size; the VM's own window is \(WindowsPlatform.display.width) × \(WindowsPlatform.display.height)."
            )
        }
    }
}
