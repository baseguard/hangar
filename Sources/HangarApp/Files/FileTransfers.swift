import Foundation
import HangarKit
import Observation

/// The copies a Files window runs: downloads, uploads and items copied out for a drag to Finder. The store counts
/// them, so quitting asks first.
@Observable
final class FileTransfers {
    private(set) var running: [FileTransfer] = []

    @ObservationIgnored private let store: VMStore
    @ObservationIgnored private var tasks: [FileTransfer.ID: Task<Void, Never>] = [:]

    init(store: VMStore) {
        self.store = store
    }

    var isEmpty: Bool { running.isEmpty }

    /// What the status bar shows: the one copy, or all of them added up.
    var summary: FileTransfer? {
        guard running.count > 1 else { return running.first }
        var total = FileTransfer(description: "Copying \(running.count) items")
        total.copied = running.reduce(0) { $0 + $1.copied }
        // A copy whose size isn't known yet leaves the sum unknown too.
        let isSizeKnown = running.allSatisfy { $0.total > 0 }
        total.total = isSizeKnown ? running.reduce(0) { $0 + $1.total } : 0
        return total
    }

    /// `work` handles its own errors; it ends early with a CancellationError when the user cancels.
    func start(_ description: String, work: @escaping (_ progress: @escaping GuestDrop.Progress) async -> Void) {
        let started = FileTransfer(description: description)
        running.append(started)
        store.runningFileTransfers += 1

        tasks[started.id] = Task {
            await work { copied, total in
                Task { @MainActor in self.showProgress(copied, of: total, for: started.id) }
            }
            running.removeAll { $0.id == started.id }
            tasks[started.id] = nil
            store.runningFileTransfers -= 1
        }
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
    }

    /// Progress that comes in after its copy ended is dropped.
    private func showProgress(_ copied: UInt64, of total: UInt64, for id: FileTransfer.ID) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        running[index].copied = copied
        running[index].total = total
    }
}

/// A download or upload as the window shows it; a total of 0 means only its end is known.
struct FileTransfer: Equatable, Identifiable {
    let id = UUID()
    let description: String
    var copied: UInt64 = 0
    var total: UInt64 = 0

    var fraction: Double? { total > 0 ? Double(copied) / Double(total) : nil }
}
