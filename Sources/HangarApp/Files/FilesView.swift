import HangarKit
import SwiftUI

/// A Finder-like window that browses a running VM's files, downloads them to this Mac and uploads to the VM.
struct FilesView: View {
    /// A table has no size of its own; the window opens as large as a display window at its smallest.
    static let defaultSize = DisplayView.minimumSize

    @Environment(VMStore.self) private var store
    @State private var browser: FilesBrowser

    init(name: String, store: VMStore) {
        _browser = State(initialValue: FilesBrowser(name: name, store: store))
    }

    var body: some View {
        let name = browser.name
        let availability = FilesAvailability(store.vm(name), agentVersion: store.usage[name]?.agentVersion)
        let isReady = availability == .ready
        NavigationSplitView {
            FilesSidebar(browser: browser)
                .disabled(!isReady)
        } detail: {
            FilesContent(browser: browser, availability: availability)
                .safeAreaInset(edge: .bottom, spacing: 0) { FilesStatusBar(browser: browser) }
        }
        .navigationTitle(browser.title)
        .navigationSubtitle(browser.title == name ? "" : name)
        .toolbarTitleMenu { FolderTitleMenu(browser: browser) }
        .toolbar { FilesToolbar(browser: browser, isReady: isReady) }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search")
        .sheet(isPresented: $browser.isGoingToFolder) { GoToFolderSheet(browser: browser) }
        .modifier(ReplaceConfirmation(browser: browser))
        .focusedSceneValue(\.selectedVM, name)
        .onChange(of: isReady, initial: true) { _, isReady in
            if isReady { browser.reload() }
        }
        .onDisappear { browser.close() }
        .modifier(StoreAlerts())
        .modifier(ClosesWhenVMIsGone(name: name, windowID: FilesWindow.id))
    }
}

/// Asks before an upload replaces files, or adds to folders, that have its names.
private struct ReplaceConfirmation: ViewModifier {
    @Bindable var browser: FilesBrowser

    func body(content: Content) -> some View {
        content.confirmationDialog(question, isPresented: isPresented($browser.pendingUpload)) {
            Button("Replace", role: .destructive) { browser.confirmUpload() }
            Button("Cancel", role: .cancel) { browser.pendingUpload = nil }
        } message: {
            Text("Files with the same names are replaced; folders with the same names are added to.")
        }
    }

    private var question: String {
        let names = browser.pendingUpload?.items.map(\.lastPathComponent) ?? []
        let folder = browser.pendingUpload.map { browser.displayName(of: $0.folder.path) } ?? ""
        if browser.pendingUpload?.folder.isTruncated == true {
            return "“\(folder)” may already have items with these names. Replace them?"
        }
        return names.count == 1
            ? "“\(names[0])” is already in “\(folder)”. Replace it?"
            : "Some of these items are already in “\(folder)”. Replace them?"
    }
}
