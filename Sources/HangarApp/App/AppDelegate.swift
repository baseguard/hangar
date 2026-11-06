import AppKit
import HangarKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIcon.apply()
        DockIcon.followWindows()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }

    /// A template opens the New VM sheet; other files, shared from Finder's Share menu or opened with Hangar, wait for
    /// the user to pick a VM.
    func application(_ application: NSApplication, open urls: [URL]) {
        let templates = urls.filter { $0.pathExtension.lowercased() == VMTemplate.fileExtension }
        let files = urls.filter { $0.pathExtension.lowercased() != VMTemplate.fileExtension }
        if let template = templates.first { VMStore.shared.ask(.newVMFromTemplate(template)) }
        if !files.isEmpty { VMStore.shared.askWhereToDrop(files) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS refuses the no-SIGPIPE flag on a socket whose peer has already closed it, such as a guest that drops
        // its end at once, and the next write would end the app with every VM in it.
        signal(SIGPIPE, SIG_IGN)

        if launchedAtLogin {
            // SwiftUI shows the main window after this returns; closing it then keeps a login start quiet.
            Task { NSApp.windows.first { $0.identifier?.rawValue == MainWindow.id }?.close() }
        } else {
            NSApp.activate()
        }

        Task { await runInBackground { VMLibrary.removeAbandonedStaging() } }
        // Here rather than in the background, so it can't race the first drag out of a Files window.
        DragExports.removeAll()
        VMStore.shared.startAutoStartVMs()
    }

    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = VMStore.shared
        let unfinished = store.unfinishedWork
        if unfinished > 0, !confirmQuit(unfinishedCount: unfinished) { return .terminateCancel }

        let count = store.sessions.count
        guard count > 0 else { return .terminateNow }
        guard confirmQuit(runningCount: count) else { return .terminateCancel }

        Task {
            await store.shutdownHostedVMs()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(unfinishedCount count: Int) -> Bool {
        confirm(
            count == 1 ? "Hangar is still working on a task." : "Hangar is still working on \(count) tasks.",
            details:
                "Quitting stops creating VMs, exporting, copying files and other work in progress; it has to start over later.",
            button: "Quit Anyway")
    }

    private func confirmQuit(runningCount count: Int) -> Bool {
        confirm(
            count == 1 ? "A virtual machine is running in Hangar." : "\(count) virtual machines are running in Hangar.",
            details: (count == 1 ? "Quitting shuts it down." : "Quitting shuts them down.")
                + " VMs started in the background or from the command line keep running.",
            button: "Shut Down and Quit")
    }

    /// Brings Hangar forward and asks; true when the user chose `button` over Cancel.
    private func confirm(_ message: String, details: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
