import AppKit
import Foundation
import HangarKit
import HangarSupport
import Observation
import UniformTypeIdentifiers

/// What a Files window shows of one VM: the folder it is in, the places in its sidebar, the way back and forward, and
/// the copies it runs.
@Observable
final class FilesBrowser {
    /// The VM's name.
    let name: String
    let transfers: FileTransfers
    var selection: Set<GuestFile.ID> = []
    var searchText = "" {
        didSet { showEntries() }
    }
    var sortOrder = [KeyPathComparator(\GuestFile.name, comparator: .localizedStandard)] {
        didSet { showEntries() }
    }
    var isGoingToFolder = false
    /// An upload with names that are in its folder already; it waits for the user to confirm replacing them.
    var pendingUpload: PendingUpload?
    private(set) var folder: GuestFolder?
    /// The folder's entries as the table shows them: those matching the search, sorted, folders on top.
    private(set) var shownEntries: [GuestFile] = []
    /// The home folder and its standard folders, found in the first listing, which is the home.
    private(set) var favorites: [GuestPlace] = []
    private(set) var listingError: String?
    private(set) var isLoading = false
    private(set) var lastOutcome: String?
    private(set) var history = FolderHistory()

    @ObservationIgnored private let store: VMStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Finder has copied these by the time another drag starts; they are leftovers in the temporary folder.
    @ObservationIgnored private var finishedDragExports: [URL] = []
    @ObservationIgnored private var isClosed = false

    init(name: String, store: VMStore) {
        self.name = name
        self.store = store
        transfers = FileTransfers(store: store)
    }

    /// Only a VM that is gone, which shows no folder, has no OS; its paths are read as Linux's.
    var os: GuestOS { store.vm(name)?.config.os ?? .linux }
    var disks: [GuestPlace] { GuestPlace.disks(of: name, os: os) }
    var homePath: String? { favorites.first?.path }

    /// The folder's name, as the window's title shows it.
    var title: String {
        guard let folder else { return name }
        return displayName(of: folder.path)
    }

    /// The folders from the disk down to the one shown, for the path bar and the title's menu.
    var enclosingFolders: [String] {
        guard let folder else { return [] }
        return GuestFileBrowser.enclosingFolders(of: folder.path, os: os)
    }

    /// The top folder / is named after the VM, as the sidebar names it.
    func displayName(of path: String) -> String {
        path == "/" ? name : GuestFileBrowser.folderName(of: path, os: os)
    }

    /// Lists the folder shown again, or the home folder when none is shown yet.
    func reload() {
        load(folder?.path) { listed in self.show(listed, keepsSelection: true) }
    }

    /// Nil opens the home folder of the user at the VM's screen. Opening the folder shown lists it again.
    func open(_ path: String?) {
        let current = folder?.path
        guard path == nil || path != current else {
            reload()
            return
        }
        load(path) { listed in
            // Nil names the home folder, which may be the one shown.
            if let current, listed.path != current { self.history.left(current) }
            self.show(listed, keepsSelection: false)
        }
    }

    func goBack() {
        guard let previous = history.back.last, let current = folder?.path else { return }
        load(previous) { listed in
            self.history.wentBack(from: current)
            self.show(listed, keepsSelection: false)
        }
    }

    func goForward() {
        guard let next = history.forward.last, let current = folder?.path else { return }
        load(next) { listed in
            self.history.wentForward(from: current)
            self.show(listed, keepsSelection: false)
        }
    }

    func goUp() {
        guard let parent = folder?.parent else { return }
        open(parent)
    }

    func goToFolder(typed: String) {
        isGoingToFolder = false
        open(GuestFileBrowser.pathToList(typed: typed))
    }

    /// A double-click: one folder opens; anything else is downloaded to Downloads and shown in Finder.
    func openItems(_ ids: Set<GuestFile.ID>) {
        let chosen = files(ids)
        if chosen.count == 1, let file = chosen.first, file.kind == .folder, let path = path(of: file) {
            open(path)
        } else {
            downloadToDownloads(ids)
        }
    }

    func download(_ ids: Set<GuestFile.ID>) {
        let chosen = downloadableFiles(ids)
        guard canCopy, !chosen.isEmpty, let destination = FilePanels.chooseDownloadFolder(for: name) else { return }
        startDownload(chosen, into: destination, revealsThem: false)
    }

    func downloadToDownloads(_ ids: Set<GuestFile.ID>) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }
        startDownload(downloadableFiles(ids), into: downloads, revealsThem: true)
    }

    /// False when only lossy items are chosen, as a download leaves them out.
    func canDownload(_ ids: Set<GuestFile.ID>) -> Bool {
        canCopy && !downloadableFiles(ids).isEmpty
    }

    /// A lossy name can't name the item back to the guest, so such items are left out.
    private func downloadableFiles(_ ids: Set<GuestFile.ID>) -> [GuestFile] {
        files(ids).filter { !$0.isLossy }
    }

    /// Upload… into the folder shown.
    func chooseUpload() {
        guard let path = folder?.path else { return }
        chooseUpload(toFolderAt: path)
    }

    /// Upload Here… into the folder `file`; one with a lossy name can't be named back to the guest.
    func chooseUpload(into file: GuestFile) {
        guard let path = path(of: file) else { return }
        chooseUpload(toFolderAt: path)
    }

    private func chooseUpload(toFolderAt path: String) {
        guard canCopy else { return }
        upload(FilePanels.chooseUploadItems(for: name, into: path), toFolderAt: path)
    }

    /// Asks first when a name is in that folder already: copying in replaces a file and adds to a folder. The folder
    /// is listed again even when it is on screen, so a file made there since isn't replaced unasked. False when
    /// nothing will be uploaded: no files from this Mac, or a copy still running. Items a drag copied out of a Files
    /// window are left out, so dropping a row back doesn't upload it.
    @discardableResult
    func upload(_ urls: [URL], toFolderAt path: String) -> Bool {
        let items = GuestDrop.localFiles(urls).filter { !DragExports.contains($0) }
        guard !items.isEmpty, canCopy else { return false }

        listThenUpload(items, toFolderAt: path)
        return true
    }

    /// Finder's files dropped between rows or below the last one; a row dragged out of this window offers no file URL.
    func upload(_ providers: [NSItemProvider], toFolderAt path: String) {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            _ = upload(urls, toFolderAt: path)
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// Files dropped on a folder's row go into that folder.
    @discardableResult
    func upload(_ urls: [URL], into file: GuestFile) -> Bool {
        guard let path = path(of: file) else { return false }
        return upload(urls, toFolderAt: path)
    }

    func confirmUpload() {
        guard let pending = pendingUpload else { return }
        pendingUpload = nil
        startUpload(pending.items, into: pending.folder)
    }

    /// One download or upload at a time per window; only drags to Finder run beside it, because Finder waits for them.
    var canCopy: Bool { folder != nil && transfers.isEmpty }

    /// The window closed: its copies stop, and what its drags left in the temporary folder goes.
    func close() {
        isClosed = true
        loading?.cancel()
        transfers.cancelAll()
        DragExports.remove(finishedDragExports)
        finishedDragExports.removeAll()
    }

    func copyPaths(of ids: Set<GuestFile.ID>) {
        let paths = ids.isEmpty ? [folder?.path].compactMap(\.self) : files(ids).compactMap(path(of:))
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func files(_ ids: Set<GuestFile.ID>) -> [GuestFile] {
        folder?.entries.filter { ids.contains($0.id) } ?? []
    }

    /// Finder turns the provider into a file promise: the item is copied out of the guest only when the drop lands.
    /// Copies leave links and special files out, so those can't be dragged.
    func dragProvider(for file: GuestFile) -> NSItemProvider? {
        guard !file.isLink, file.kind != .other, !file.isLossy, let folder else { return nil }
        DragExports.remove(finishedDragExports)
        finishedDragExports.removeAll()

        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let type = file.contentType.identifier
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { finished in
            Task { @MainActor in self.copyOutForDrag(file, from: folder, finished: finished) }
            return nil
        }
        return provider
    }

    /// Copies one dragged item into a folder of its own, so it keeps its name, and hands it to Finder; a failure or
    /// Cancel in the status bar hands Finder the error instead.
    private func copyOutForDrag(
        _ file: GuestFile, from folder: GuestFolder,
        finished: @escaping @Sendable (_ copy: URL?, _ coordinated: Bool, _ error: (any Error)?) -> Void
    ) {
        guard let vm = store.vm(name) else {
            finished(nil, false, HangarError("'\(name)' is gone. Open its files again."))
            return
        }
        let exportFolder: URL
        do {
            exportFolder = try DragExports.makeFolder()
        } catch {
            finished(nil, false, error)
            return
        }

        let os = vm.config.os
        let bundle = vm.bundle
        transfers.start("Copying “\(file.name)” to this Mac") { progress in
            var isHandedToFinder = false
            do {
                let downloaded = try await GuestFileBrowser.download(
                    [file], from: folder, os: os, into: exportFolder, in: bundle, progress: progress)
                finished(downloaded.saved.first, false, nil)
                isHandedToFinder = true
            } catch {
                finished(nil, false, error)
                if !(error is CancellationError) { self.store.report(error, doing: "copy “\(file.name)” to this Mac") }
            }
            self.dragCopyEnded(in: exportFolder, isHandedToFinder: isHandedToFinder)
        }
    }

    /// After its window closed, no later drag removes a copy's folder, so a failed copy's goes at once; one handed to
    /// Finder may still be read, so it waits for the app's next launch.
    private func dragCopyEnded(in exportFolder: URL, isHandedToFinder: Bool) {
        if isClosed, !isHandedToFinder {
            DragExports.remove([exportFolder])
        } else {
            finishedDragExports.append(exportFolder)
        }
    }

    private func startDownload(_ chosen: [GuestFile], into destination: URL, revealsThem: Bool) {
        guard canCopy, !chosen.isEmpty, let folder, let vm = store.vm(name) else { return }
        let os = vm.config.os
        let bundle = vm.bundle
        let place = destination.lastPathComponent

        let description = "Downloading \(title(of: chosen.map(\.name)))"
        startCopy(description, failure: "download from \(name)", cancelled: "Download cancelled.") { progress in
            let downloaded = try await GuestFileBrowser.download(
                chosen, from: folder, os: os, into: destination, in: bundle, progress: progress)
            if revealsThem { NSWorkspace.shared.activateFileViewerSelecting(downloaded.saved) }
            return "Downloaded to “\(place)”." + Self.skippedNote(downloaded.skipped)
        }
    }

    private func listThenUpload(_ items: [URL], toFolderAt path: String) {
        guard let bundle = store.vm(name)?.bundle else { return }
        Task {
            do {
                askOrUpload(items, into: try await GuestFileBrowser.list(path, in: bundle))
            } catch {
                store.report(error, doing: "upload to \(name)")
            }
        }
    }

    /// A truncated listing holds only the folder's first names, so any of the items may be there already.
    private func askOrUpload(_ items: [URL], into target: GuestFolder) {
        // Lowercased: macOS and Windows guests treat "Notes" and "notes" as one name.
        let namesThere = Set(target.entries.map { $0.name.lowercased() })
        let hasNameThere = items.contains { namesThere.contains($0.lastPathComponent.lowercased()) }
        if hasNameThere || target.isTruncated {
            pendingUpload = PendingUpload(items: items, folder: target)
        } else {
            startUpload(items, into: target)
        }
    }

    private func startUpload(_ items: [URL], into target: GuestFolder) {
        // A drop's target is listed first, and another copy may have started meanwhile.
        guard canCopy, let bundle = store.vm(name)?.bundle else { return }
        let itemNames = items.map(\.lastPathComponent)
        let place = displayName(of: target.path)
        let cancelled = "Upload cancelled; \(title(of: itemNames)) in “\(place)” may be incomplete."

        startCopy("Uploading \(title(of: itemNames))", failure: "upload to \(name)", cancelled: cancelled) { progress in
            // Even a failed or cancelled upload may have put part of it there; a listing the user started meanwhile
            // is left to finish rather than cancelled.
            defer { if !self.isLoading { self.reload() } }
            let skipped = try await GuestFileBrowser.upload(items, into: target, in: bundle, progress: progress)
            return "Uploaded to “\(place)”." + Self.skippedNote(skipped)
        }
    }

    /// `work` returns how the copy ended; `cancelled` says it when the user cancelled.
    private func startCopy(
        _ description: String, failure action: String, cancelled: String,
        work: @escaping (_ progress: @escaping GuestDrop.Progress) async throws -> String
    ) {
        lastOutcome = nil
        transfers.start(description) { progress in
            do {
                self.lastOutcome = try await work(progress)
            } catch is CancellationError {
                self.lastOutcome = cancelled
            } catch {
                self.store.report(error, doing: action)
            }
        }
    }

    /// `show` runs only when the listing arrives, so a failed move keeps the window and its history as they were.
    private func load(_ path: String?, then show: @escaping (GuestFolder) -> Void) {
        guard let bundle = store.vm(name)?.bundle else { return }
        loading?.cancel()
        isLoading = true

        loading = Task {
            do {
                let listed = try await GuestFileBrowser.list(path, in: bundle)
                guard !Task.isCancelled else { return }
                if path == nil || listed.path == homePath { favorites = GuestPlace.favorites(in: listed, os: os) }
                show(listed)
            } catch {
                guard !Task.isCancelled else { return }
                showListingError(error)
            }
            isLoading = false
        }
    }

    private func show(_ listed: GuestFolder, keepsSelection: Bool) {
        let names = Set(listed.entries.map(\.id))
        selection = keepsSelection ? selection.intersection(names) : []
        folder = listed
        listingError = nil
        if !keepsSelection { searchText = "" }
        showEntries()
    }

    private func showEntries() {
        let entries = folder?.entries ?? []
        let matching = searchText.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(searchText) }
        let sorted = matching.sorted(using: sortOrder)
        // Folders stay on top whichever column sorts, like Finder's Keep Folders on Top.
        shownEntries = sorted.filter { $0.kind == .folder } + sorted.filter { $0.kind != .folder }
    }

    /// With a folder on screen, a folder that can't be opened is an alert and the window stays where it was.
    private func showListingError(_ error: any Error) {
        guard folder != nil else {
            listingError = error.localizedDescription
            return
        }
        store.report(error, doing: "open the folder in \(name)")
    }

    /// Nil for a lossy name, which can't name the item back to the guest.
    private func path(of file: GuestFile) -> String? {
        guard let folder, !file.isLossy else { return nil }
        return GuestFileBrowser.path(of: file.name, in: folder.path, os: os)
    }

    private func title(of names: [String]) -> String {
        names.count == 1 ? "“\(names[0])”" : "\(names.count) items"
    }

    private static func skippedNote(_ skipped: Int) -> String {
        guard skipped > 0 else { return "" }
        return " Left out \(skipped) \(counted(skipped, "link")) or special \(counted(skipped, "file"))."
    }
}

/// Items to upload into `folder`, which has some of their names already or may have them, when its listing was
/// truncated.
struct PendingUpload {
    let items: [URL]
    let folder: GuestFolder
}
