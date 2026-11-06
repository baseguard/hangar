import AppKit
import HangarSupport
import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @State private var loginItem = SMAppService.mainApp.status
    @State private var message: String?
    @AppStorage(MenuBarMenu.visibilityKey) private var showsMenuBarItem = true
    @AppStorage(DockIcon.visibilityKey) private var showsDockIcon = true

    var body: some View {
        Form {
            LoginItemSection(isOn: launchesAtLogin, needsApproval: loginItem == .requiresApproval)
            Section {
                Toggle("Show in the menu bar", isOn: $showsMenuBarItem)
                    .disabled(!showsDockIcon)
                Toggle("Show in the Dock", isOn: $showsDockIcon)
                    .disabled(!showsMenuBarItem)
            } footer: {
                Text("Hangar always stays in the menu bar or the Dock, so one of them remains on.")
            }
            VMLibrarySection()
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem = SMAppService.mainApp.status }
    }

    private var launchesAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem == .enabled || loginItem == .requiresApproval },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginItem = SMAppService.mainApp.status
    }
}

private struct LoginItemSection: View {
    let isOn: Binding<Bool>
    let needsApproval: Bool

    var body: some View {
        Section {
            Toggle("Open Hangar at login", isOn: isOn)
                .disabled(Bundle.main.bundleIdentifier == nil)
            if needsApproval {
                LabeledContent {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                } label: {
                    Notice(
                        text: "Allow Hangar in System Settings → Login Items.",
                        systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
        } footer: {
            Text(
                "At login, Hangar opens in the menu bar without a window and starts the VMs set to start automatically."
            )
        }
    }
}

private struct VMLibrarySection: View {
    var body: some View {
        Section {
            LabeledContent("VM library") {
                Button(HangarPaths.home.path) {
                    _ = try? HangarPaths.createDirectory(HangarPaths.home)
                    NSWorkspace.shared.open(HangarPaths.home)
                }
                .buttonStyle(.link)
            }
        }
    }
}
