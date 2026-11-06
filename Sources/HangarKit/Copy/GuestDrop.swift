import Darwin
import Foundation
import HangarSupport
import Synchronization

/// Drops files into a VM without a shared folder: the Mac streams them as one archive to the guest agent's `take` over
/// `hangar exec`, which puts them in the HangarDrop folder in the home of the user at the guest's screen.
package enum GuestDrop {
    package typealias Progress = @Sendable (_ copied: UInt64, _ total: UInt64) -> Void

    /// The guest's reason is shown in an alert; a guest can't flood it.
    static let reasonLimit = 1024

    /// Only files on this Mac can be dropped; links like https: or a custom scheme are left out.
    package static func localFiles(_ urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL)
    }

    /// Stops with a CancellationError when the task running it is cancelled, or `stop` is used from another thread.
    package static func drop(
        _ items: [URL], into bundle: VMBundle, stop: CopyStop = CopyStop(), progress: @escaping Progress = { _, _ in }
    ) throws {
        try GuestCopy.checkAgent(of: bundle, needs: GuestSetup.firstDropAgentVersion, for: "Dropping files")
        let (connection, descriptor) = try GuestCopy.open(["take"], sendsInput: true, in: bundle)
        GuestCopy.limitWait(SO_SNDTIMEO, of: descriptor, to: GuestCopy.sendTimeout)
        try GuestCopy.run(over: descriptor, vm: bundle.name, stop: stop) {
            try take(items, over: connection, descriptor: descriptor, in: bundle, progress: progress)
        }
    }

    /// The agent's `take` reads the archive; its own reason for stopping comes before this Mac's.
    private static func take(
        _ items: [URL], over connection: ExecConnection, descriptor: Int32, in bundle: VMBundle,
        progress: @escaping Progress
    ) throws {
        let reason = Mutex(Data())
        let exit = GuestCopy.Exit(reading: descriptor) { piece in
            reason.withLock { $0.append(piece.prefix(max(0, reasonLimit - $0.count))) }
        }

        do {
            try send(items, over: connection, progress: progress)
        } catch is GuestStoppedTaking {
            try? exit.wait(in: bundle, upTo: GuestCopy.endTimeout)
            throw guestReason(reason.withLock { $0 }, vm: bundle.name)
                ?? HangarError("'\(bundle.name)' stopped taking the files.")
        }

        do {
            try exit.wait(in: bundle, upTo: GuestCopy.endTimeout)
        } catch {
            throw guestReason(reason.withLock { $0 }, vm: bundle.name) ?? signInSentence(for: error, vm: bundle.name)
        }
    }

    /// The agent stopped taking the archive; its own reason says why, not this Mac's failed write.
    struct GuestStoppedTaking: Error {}

    /// The archive with each item under a name of its own, then the end of the agent's input. A failure to read a file
    /// on this Mac is thrown as it is.
    private static func send(_ items: [URL], over connection: ExecConnection, progress: @escaping Progress) throws {
        let count = progressCounter(total: items.reduce(0) { $0 + size(of: $1) }, progress: progress)
        var writer = CopyArchiveWriter { piece in
            try Task.checkCancellation()
            do {
                try connection.send(ExecFrame(.input, payload: piece))
            } catch {
                throw GuestStoppedTaking()
            }
            count(piece.count)
        }

        var names: Set<String> = []
        for item in items {
            try writer.write(item, as: unusedName(item.lastPathComponent, in: &names))
        }
        try writer.finish()
        try connection.send(ExecFrame(.input, payload: Data()))
    }

    /// What the agent said went wrong, without control characters.
    static func guestReason(_ errors: Data, vm: String) -> HangarError? {
        let message = String(decoding: errors.withoutControlCharacters, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : HangarError(message)
    }

    /// With nobody signed in at the guest's screen, `hangar exec` has no user to run `take` as.
    static func signInSentence(for error: any Error, vm: String) -> any Error {
        guard (error as? HangarError)?.message.hasPrefix("Nobody is signed in") == true else { return error }
        return HangarError("Sign in to '\(vm)' first, then drop the files again.")
    }

    /// Reports in whole percent steps, so a copy of many small files doesn't flood the window with updates.
    static func progressCounter(total: UInt64, progress: @escaping Progress) -> (Int) -> Void {
        var bytes: UInt64 = 0
        var reported: UInt64 = 0
        progress(0, total)
        return { sent in
            bytes = min(total, bytes + UInt64(sent))
            let percent = total > 0 ? bytes * 100 / total : 100
            if percent > reported {
                reported = percent
                progress(bytes, total)
            }
        }
    }

    /// Two dropped items with one name, from different folders, both arrive: the second as "name 2".
    static func unusedName(_ name: String, in names: inout Set<String>) -> String {
        var candidate = name
        var number = 2
        while names.contains(candidate.lowercased()) {
            candidate = numberedName(name, number)
            number += 1
        }
        names.insert(candidate.lowercased())
        return candidate
    }

    /// "report.pdf" numbered 2 is "report 2.pdf", like Finder names a second copy.
    static func numberedName(_ name: String, _ number: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        return "\(base) \(number)\(suffix)"
    }

    static func size(of url: URL) -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return UInt64(info.st_size)
        case S_IFDIR:
            let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return children.reduce(0) { $0 + size(of: url.appendingPathComponent($1)) }
        default:
            return 0
        }
    }
}
