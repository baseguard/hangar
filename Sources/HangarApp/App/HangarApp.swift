import AppKit
import HangarKit
import HangarSupport
import SwiftUI

@main
enum Main {
    static func main() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent(HangarExecutable.bundledPath)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("hangar")
        HangarExecutable.url = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : sibling
        HangarApp.main()
    }
}

struct HangarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = VMStore.shared
    @AppStorage(MenuBarMenu.visibilityKey) private var showsMenuBarItem = true
    @AppStorage(DockIcon.visibilityKey) private var showsDockIcon = true

    var body: some Scene {
        Window("Hangar", id: MainWindow.id) {
            ContentView()
                .environment(store)
        }
        .defaultWindowPlacement { _, context in
            centered(
                ContentView.idealSize, minimum: ContentView.minimumSize, fraction: ContentView.screenFraction,
                in: context)
        }
        // Files shared or opened with Hangar go to AppDelegate. A scene that took them too would have SwiftUI hide this
        // window and show it again for every file.
        .handlesExternalEvents(matching: [])
        .windowToolbarStyle(.unified)
        .windowToolbarLabelStyle(fixed: .iconOnly)
        .onChange(of: showsDockIcon) { DockIcon.settingChanged() }
        .onChange(of: showsMenuBarItem) { DockIcon.settingChanged() }
        .commands { HangarCommands(store: store) }

        DisplayWindows(store: store)
        FilesWindows(store: store)

        Window("Drop Files", id: DropWindow.id) {
            DropWindow()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])
        .commandsRemoved()
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .modifier(StoreAlerts())
                .environment(store)
        }

        MenuBarExtra(
            "Hangar",
            systemImage: store.vms.contains(where: \.isRunning)
                ? "square.3.layers.3d.top.filled" : "square.3.layers.3d",
            isInserted: $showsMenuBarItem
        ) {
            MenuBarMenu()
                .environment(store)
        }
    }
}

private struct DisplayWindows: Scene {
    let store: VMStore

    var body: some Scene {
        WindowGroup("Display", id: DisplayWindow.id, for: String.self) { $name in
            if let name {
                DisplayView(name: name)
                    .environment(store)
            }
        }
        .defaultWindowPlacement { _, context in
            centered(
                DisplayView.idealSize, minimum: DisplayView.minimumSize, fraction: DisplayView.screenFraction,
                in: context)
        }
        .handlesExternalEvents(matching: [])
        .windowToolbarLabelStyle(fixed: .iconOnly)
    }
}

private struct FilesWindows: Scene {
    let store: VMStore

    var body: some Scene {
        WindowGroup("Files", id: FilesWindow.id, for: String.self) { $name in
            if let name {
                FilesView(name: name, store: store)
                    .environment(store)
            }
        }
        .defaultSize(FilesView.defaultSize)
        .handlesExternalEvents(matching: [])
        .windowToolbarLabelStyle(fixed: .iconOnly)
    }
}

private struct HangarCommands: Commands {
    let store: VMStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") { store.ask(.newVM(nil)) }
                .keyboardShortcut("n")
        }
        SidebarCommands()
        CommandGroup(before: .sidebar) { PageCommands().environment(store) }
        VMMenu(store: store)
    }
}

private func centered(
    _ size: CGSize, minimum: CGSize, fraction: CGFloat, in context: WindowPlacementContext
) -> WindowPlacement {
    WindowPlacement(
        .center,
        size: fitted(size, minimum: minimum, in: context.defaultDisplay.visibleRect.size, fraction: fraction))
}

private func fitted(_ size: CGSize, minimum: CGSize, in screen: CGSize, fraction: CGFloat) -> CGSize {
    CGSize(
        width: min(size.width, max(minimum.width, screen.width * fraction)),
        height: min(size.height, max(minimum.height, screen.height * fraction)))
}
