import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Prune: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete downloads Hangar hasn't used for a while.",
        discussion: """
            Examples:
              hangar prune --older-than 30
                  Delete images, IPSWs and ISOs not used in 30 days.
              hangar prune --space-budget 100
                  Keep the most recently used downloads within 100 GB.

            VMs are never touched, and downloads in use are skipped. The same downloads are in Settings › Downloads.
            """
    )

    @Option(help: ArgumentHelp("Delete downloads not used for this many days.", valueName: "days")) var olderThan: Int?
    @Option(
        help: ArgumentHelp("Then delete the least recently used until the rest fit in this many GB.", valueName: "gb"))
    var spaceBudget: UInt64?

    /// Far past any Mac's disk; keeps the multiplication below in range.
    private static let largestBudgetGB: UInt64 = 1 << 20

    func validate() throws {
        guard (spaceBudget ?? 0) <= Self.largestBudgetGB else {
            throw ValidationError("Give a space budget up to \(Self.largestBudgetGB) GB.")
        }
    }

    func run() throws {
        runMain { [olderThan, spaceBudget] in
            let chosen = try await CacheStore.pruneList(
                olderThanDays: olderThan, spaceBudget: spaceBudget.map { $0 * ByteSize.gib })
            guard !chosen.isEmpty else {
                print("Nothing to delete.")
                return
            }

            var freed: UInt64 = 0
            var kept = 0
            for entry in chosen {
                do {
                    try await CacheStore.delete(entry)
                    freed += entry.size
                    print("Deleted \(entry.title) (\(ByteSize.format(entry.size))).")
                } catch {
                    kept += 1
                    printError("Kept \(entry.title): \(error.localizedDescription)")
                }
            }
            print("Freed \(ByteSize.format(freed)).")
            guard kept == 0 else { throw HangarError("\(kept) download\(kept == 1 ? "" : "s") could not be deleted.") }
        }
    }
}
