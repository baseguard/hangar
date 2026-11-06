import HangarKit
import SwiftUI

/// The table's context menu: for the clicked items, or for the folder shown when the click is on empty space.
struct FileMenuItems: View {
    let browser: FilesBrowser
    let ids: Set<GuestFile.ID>

    var body: some View {
        if ids.isEmpty {
            FolderMenuItems(browser: browser)
        } else {
            ItemMenuItems(browser: browser, ids: ids)
        }
    }
}

private struct ItemMenuItems: View {
    let browser: FilesBrowser
    let ids: Set<GuestFile.ID>

    var body: some View {
        if let folder = onlyFolder {
            Button("Open") { browser.openItems(ids) }
            Button("Upload Here…") { browser.chooseUpload(into: folder) }
                .disabled(!browser.canCopy)
            Divider()
        }
        Button("Download…") { browser.download(ids) }
            .disabled(!browser.canDownload(ids))
        Button("Download to Downloads") { browser.downloadToDownloads(ids) }
            .disabled(!browser.canDownload(ids))
        Divider()
        Button("Copy Path") { browser.copyPaths(of: ids) }
    }

    /// Open and Upload Here… are for one folder whose name can name it back to the guest.
    private var onlyFolder: GuestFile? {
        let chosen = browser.files(ids)
        guard chosen.count == 1, let file = chosen.first, file.kind == .folder, !file.isLossy else { return nil }
        return file
    }
}

private struct FolderMenuItems: View {
    let browser: FilesBrowser

    var body: some View {
        Button("Upload…") { browser.chooseUpload() }
            .disabled(!browser.canCopy)
        Button("Go to Folder…") { browser.isGoingToFolder = true }
        Button("Reload") { browser.reload() }
        Divider()
        Button("Copy Path") { browser.copyPaths(of: []) }
    }
}
