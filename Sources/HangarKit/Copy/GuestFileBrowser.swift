import Darwin
import Foundation
import HangarSupport
import Synchronization

/// Browses a running VM's files for the app's Files window: the guest agent's `ls` lists a folder over `hangar exec`,
/// and `hangar cp`'s two directions download and upload the chosen items.
package enum GuestFileBrowser {
    /// The agent caps its own listing; a guest that sends more than this is refused rather than held in memory.
    static let largestListing = 8 << 20

    /// The folder at `path` in the guest, or the home folder of the user at its screen when `path` is nil. A relative
    /// path is relative to that home. Cancelling the task ends it at once, even on a guest that stopped answering.
    @concurrent
    package static func list(_ path: String?, in bundle: VMBundle) async throws -> GuestFolder {
        try GuestCopy.checkAgent(of: bundle, needs: GuestSetup.firstBrowseAgentVersion, for: "Browsing files")
        let arguments = ["ls"] + (path.map { [$0] } ?? [])
        let shownPath = path ?? "the home folder"
        let stop = CopyStop()

        let listing = try await withTaskCancellationHandler {
            let (connection, descriptor) = try GuestCopy.open(arguments, sendsInput: false, in: bundle)
            GuestCopy.limitWait(SO_RCVTIMEO, of: descriptor, to: GuestCopy.receiveTimeout)
            return try GuestCopy.run(over: descriptor, vm: bundle.name, stop: stop, activity: "the listing") {
                try readListing(from: connection, path: shownPath, vm: bundle.name)
            }
        } onCancel: {
            stop.stop()
        }
        return try folder(from: listing, vm: bundle.name)
    }

    /// What a download wrote on this Mac.
    package struct Downloaded: Equatable, Sendable {
        /// One per downloaded item, under the name it got.
        package var saved: [URL] = []
        /// Links and special files left out.
        package var skipped = 0
    }

    /// Copies `files` from `folder` into `destination` on this Mac. Each keeps its name unless one is there already,
    /// then it gets a number, like a download. Cancelling the task ends it at once, even on a guest that stopped
    /// answering.
    @concurrent
    package static func download(
        _ files: [GuestFile], from folder: GuestFolder, os: GuestOS, into destination: URL, in bundle: VMBundle,
        progress: @escaping GuestDrop.Progress
    ) async throws -> Downloaded {
        let localNames = try files.map(localName(of:))
        let count = GuestDrop.progressCounter(total: downloadSize(of: files), progress: progress)
        var downloaded = Downloaded()
        let stop = CopyStop()

        try await withTaskCancellationHandler {
            for (file, localName) in zip(files, localNames) {
                let guestPath = path(of: file.name, in: folder.path, os: os)
                let item = try downloadItem(
                    guestPath, as: localName, into: destination, in: bundle, stop: stop, received: count)
                downloaded.saved.append(item.saved)
                downloaded.skipped += item.skipped
            }
        } onCancel: {
            stop.stop()
        }
        return downloaded
    }

    /// The bytes the files' listing gave, or 0 with a folder among them, which has no size there. Each size is the
    /// guest's word; capped at what a copy may hold, the sum can't overflow.
    static func downloadSize(of files: [GuestFile]) -> UInt64 {
        guard files.allSatisfy({ $0.kind == .file }) else { return 0 }
        return files.reduce(0) { $0 + min($1.size, CopyExtractor.largestCopy) }
    }

    /// A folder of the item's own in `destination`: the item is copied there, then moved out under a free name, so
    /// removing it after a Cancel can't touch anything of the user's. Visible, like Safari's .download, so what a
    /// quit in the middle leaves behind can be seen and thrown away.
    private static func makeStagingFolder(for name: String, in destination: URL) throws -> URL {
        let id = UUID().uuidString.prefix(8).lowercased()
        let staging = destination.appendingPathComponent(stagingName(for: name, id: id), isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else {
            throw HangarError(errno: errno, "Could not download into \(destination.path)")
        }
        return staging
    }

    /// "<name> (downloading <id>)", the name cut short so the whole stays within a file name's 255 bytes.
    static func stagingName(for name: String, id: String) -> String {
        let suffix = " (downloading \(id))"
        var shortName = name
        while shortName.utf8.count + suffix.utf8.count > Int(NAME_MAX) {
            shortName.removeLast()
        }
        return shortName + suffix
    }

    /// Copies one item into a staging folder as `name`, then moves it into `destination`. A cancelled copy goes with
    /// the staging folder.
    private static func downloadItem(
        _ guestPath: String, as name: String, into destination: URL, in bundle: VMBundle, stop: CopyStop,
        received: @escaping (Int) -> Void
    ) throws -> (saved: URL, skipped: Int) {
        let staging = try makeStagingFolder(for: name, in: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(name)
        let copied: GuestCopy.Outcome
        do {
            copied = try withGuestReason(in: bundle, forAnyFailure: true) { errors in
                try GuestCopy.copyOut(
                    guestPath, into: staging, as: name, in: bundle, errors: errors, stop: stop, received: received)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The copy's error says the files written before it stay, so they are moved out too.
            _ = try? moveToFreeName(staged, into: destination)
            throw error
        }
        return (try moveToFreeName(staged, into: destination), copied.skipped)
    }

    /// Gives up on a folder full of "name 2", "name 3" and on.
    static let mostNumberedNames = 1000

    /// Moves `item` into `folder` under its own name, or the first numbered one free there. The rename itself refuses a
    /// taken name, so it never replaces an item that appeared meanwhile or whose name differs only in case or form.
    static func moveToFreeName(_ item: URL, into folder: URL) throws -> URL {
        let name = item.lastPathComponent
        for number in 1...mostNumberedNames {
            let candidate = folder.appendingPathComponent(number == 1 ? name : GuestDrop.numberedName(name, number))
            if try FileMove.withoutReplacing(item, to: candidate) { return candidate }
        }
        throw HangarError("\(folder.path) has too many items named like \(name); choose another folder.")
    }

    /// Copies `items` on this Mac into `folder` in the guest; an item with a name already there replaces that file or
    /// adds to that folder, like `hangar cp`. Returns how many links or special files were left out. Cancelling the
    /// task ends it at once, even on a guest that stopped answering.
    @concurrent
    package static func upload(
        _ items: [URL], into folder: GuestFolder, in bundle: VMBundle, progress: @escaping GuestDrop.Progress
    ) async throws -> Int {
        let total = items.reduce(0) { $0 + GuestDrop.size(of: $1) }
        let count = GuestDrop.progressCounter(total: total, progress: progress)
        var skipped = 0
        let stop = CopyStop()

        try await withTaskCancellationHandler {
            for item in items {
                skipped += try withGuestReason(in: bundle, forAnyFailure: false) { errors in
                    try GuestCopy.copyIn(item, to: folder.path, in: bundle, errors: errors, stop: stop, sent: count)
                }
            }
        } onCancel: {
            stop.stop()
        }
        return skipped
    }

    /// `name` inside the guest folder at `folder`, joined with the guest's own separator: a root such as / or C:\
    /// already ends with it.
    package static func path(of name: String, in folder: String, os: GuestOS) -> String {
        let separator = String(pathSeparator(of: os))
        return folder.hasSuffix(separator) ? folder + name : folder + separator + name
    }

    private static func pathSeparator(of os: GuestOS) -> Character {
        os == .windows ? "\\" : "/"
    }

    /// The folders from the top down to `path` itself: /home/dev gives /, /home and /home/dev; C:\Users gives C:\
    /// and C:\Users.
    package static func enclosingFolders(of path: String, os: GuestOS) -> [String] {
        let separator = pathSeparator(of: os)
        var names = path.split(separator: separator).map(String.init)
        // A Windows path starts with its drive, whose top folder keeps the separator: C:\.
        let top = os == .windows && !names.isEmpty ? names.removeFirst() + "\\" : String(separator)

        var folders = [top]
        var current = top
        for name in names {
            current = self.path(of: name, in: current, os: os)
            folders.append(current)
        }
        return folders
    }

    /// The last name in `path`, or the top folder itself: / or C:.
    package static func folderName(of path: String, os: GuestOS) -> String {
        path.split(separator: pathSeparator(of: os)).last.map(String.init) ?? path
    }

    /// The path to list for what the user typed in Go to Folder; nil is the home folder, as for `hangar-agent ls`
    /// without a path. A leading ~ means that home, like in Finder; the agent lists a relative path from there.
    package static func pathToList(typed: String) -> String? {
        let path = typed.trimmingCharacters(in: .whitespaces)
        guard path != "", path != "~" else { return nil }
        guard path.hasPrefix("~/") || path.hasPrefix("~\\") else { return path }
        return String(path.dropFirst(2))
    }

    /// The guest named the item, so its name is checked before it becomes a file on this Mac. A lossy name isn't the
    /// guest's own, so the guest would copy another item or none.
    static func localName(of file: GuestFile) throws -> String {
        let name = file.name
        guard !file.isLossy else {
            throw HangarError("“\(CopyArchive.printable(name))” can't be read exactly on this Mac.")
        }
        let isPlainName = !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
        guard isPlainName else {
            throw HangarError("“\(CopyArchive.printable(name))” can't be a file name on this Mac.")
        }
        return name
    }

    /// The listing as the agent printed it, sorted folders first, then by name as Finder sorts.
    static func folder(from listing: Data, vm: String) throws -> GuestFolder {
        guard var folder = try? JSONDecoder().decode(GuestFolder.self, from: listing) else {
            throw HangarError("The listing from '\(vm)' couldn't be read. Update its agent and try again.")
        }

        folder.entries = withoutRepeatedNames(folder.entries)
        folder.entries.sort(by: GuestFile.isListedBefore)
        return folder
    }

    /// The window tells items apart by name. Two names a String can't tell apart, such as the NFC and NFD forms of one
    /// name or two that weren't UTF-8, keep only the first rather than hiding the whole folder.
    private static func withoutRepeatedNames(_ entries: [GuestFile]) -> [GuestFile] {
        var seen: Set<String> = []
        var kept: [GuestFile] = []
        for entry in entries {
            let isFirstWithItsName = seen.insert(entry.name).inserted
            if isFirstWithItsName { kept.append(entry) }
        }
        return kept
    }

    /// The command's output; on a failed exit, the guest's own sentence on why.
    private static func readListing(from connection: ExecConnection, path: String, vm: String) throws -> Data {
        let reason = Mutex(Data())
        var output = GuestCopy.OutputReader(connection) { piece in
            reason.withLock { $0.append(piece.prefix(max(0, GuestDrop.reasonLimit - $0.count))) }
        }

        var listing = Data()
        while let piece = try output.next() {
            listing.append(piece)
            guard listing.count <= largestListing else {
                let limit = ByteSize.format(UInt64(largestListing))
                throw HangarError("The listing of \(path) in '\(vm)' is larger than \(limit).")
            }
        }
        guard output.exitCode == 0 else {
            throw guestSentence(reason.withLock { $0 }, vm: vm) ?? HangarError("Could not list \(path) in '\(vm)'.")
        }
        return listing
    }

    /// Runs one copy and throws the agent's own reason instead of this Mac's "The copy failed". `forAnyFailure` suits a
    /// download: the Mac only reads, so anything the agent said is why the copy stopped short. In an upload a failure on
    /// this Mac's side stays as it is: the agent's complaint about the cut-off copy isn't the cause.
    static func withGuestReason<T>(
        in bundle: VMBundle, forAnyFailure: Bool, _ copy: (@escaping GuestCopy.ErrorOutput) throws -> T
    ) throws -> T {
        let reason = Mutex(Data())
        do {
            return try copy { piece in
                reason.withLock { $0.append(piece.prefix(max(0, GuestDrop.reasonLimit - $0.count))) }
            }
        } catch let error as GuestCopy.CopyFailed {
            throw guestSentence(reason.withLock { $0 }, vm: bundle.name) ?? error
        } catch let error as HangarError {
            guard forAnyFailure else { throw error }
            throw guestSentence(reason.withLock { $0 }, vm: bundle.name) ?? error
        }
    }

    /// What the agent said went wrong, without the "hangar-agent: " it puts before each of its errors.
    static func guestSentence(_ errors: Data, vm: String) -> HangarError? {
        guard let reason = GuestDrop.guestReason(errors, vm: vm) else { return nil }
        let prefix = "hangar-agent: "
        guard reason.message.hasPrefix(prefix) else { return reason }
        return HangarError(String(reason.message.dropFirst(prefix.count)))
    }
}
