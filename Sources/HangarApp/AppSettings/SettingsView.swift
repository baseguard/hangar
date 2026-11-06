import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 520

    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
                .help("Startup, menu bar and Dock")
            Tab("Network", systemImage: "network", value: "network") { SharedNetworkSettings() }
                .help("The subnet of Hangar's network")
            Tab("Downloads", systemImage: "internaldrive", value: "downloads") { DownloadSettings() }
                .help("Downloaded images and installed macOS kept for new VMs")
            Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") { AccountsSettings() }
                .help("Registries Hangar signs in to")
            Tab("Command Line", systemImage: "apple.terminal", value: "commandLine") { CommandLineSettings() }
                .help("Install the hangar command")
        }
        .frame(width: Self.width)
        .scenePadding(.minimum, edges: .bottom)
    }
}
