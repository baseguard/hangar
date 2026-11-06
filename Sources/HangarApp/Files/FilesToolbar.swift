import HangarKit
import SwiftUI

/// Finder's Back and Forward, the window's copies and its actions; nothing works until the VM's files can be listed.
struct FilesToolbar: ToolbarContent {
    let browser: FilesBrowser
    let isReady: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { browser.goBack() }
                .keyboardShortcut("[")
                .help("See folders you viewed previously")
                .disabled(!isReady || !browser.history.canGoBack)
            Button("Forward", systemImage: "chevron.forward") { browser.goForward() }
                .keyboardShortcut("]")
                .help("See folders you viewed next")
                .disabled(!isReady || !browser.history.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Download…", systemImage: "arrow.down.circle") { browser.download(browser.selection) }
                .help("Download the selected items to this Mac")
                .disabled(!isReady || !browser.canDownload(browser.selection))
            Button("Upload…", systemImage: "arrow.up.circle") { browser.chooseUpload() }
                .help("Upload files and folders from this Mac to this folder")
                .disabled(!isReady || !browser.canCopy)
        }
        ToolbarItem(placement: .primaryAction) {
            FolderActionsMenu(browser: browser)
                .disabled(!isReady)
        }
    }
}

/// Like Finder's action menu, with the Go menu's moves Finder keeps in its menu bar.
private struct FolderActionsMenu: View {
    let browser: FilesBrowser

    var body: some View {
        Menu("Actions", systemImage: "ellipsis.circle") {
            Button("Enclosing Folder") { browser.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(browser.folder?.parent == nil)
            Button("Go to Folder…") { browser.isGoingToFolder = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Reload") { browser.reload() }
            Divider()
            Button("Download to Downloads") { browser.downloadToDownloads(browser.selection) }
                .disabled(!browser.canDownload(browser.selection))
            Button("Copy Path") { browser.copyPaths(of: browser.selection) }
        }
        .help("Actions for this folder and the selected items")
    }
}
