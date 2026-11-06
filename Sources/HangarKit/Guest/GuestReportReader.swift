import Foundation
import Synchronization

package struct GuestReportReader: Sendable {
    static let lineLimit = 4096
    static let staleAfter: TimeInterval = 10
    static let minimumInterval: TimeInterval = 0.5

    private var line: [UInt8] = []
    private var overflowed = false
    private var latest: (report: GuestReport, at: Date)?

    package init() {}

    package mutating func feed(_ bytes: some Collection<UInt8>, now: Date) {
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                let due = latest.map { now.timeIntervalSince($0.at) >= Self.minimumInterval } ?? true
                if !overflowed, due, let report = Self.parse(line) { latest = (report, now) }
                line.removeAll(keepingCapacity: true)
                overflowed = false
            } else if line.count < Self.lineLimit {
                line.append(byte)
            } else {
                overflowed = true
            }
        }
    }

    package func report(at now: Date) -> GuestReport? {
        guard let latest, now.timeIntervalSince(latest.at) <= Self.staleAfter else { return nil }
        return latest.report
    }

    static func parse(_ line: [UInt8]) -> GuestReport? {
        try? JSONDecoder().decode(GuestReport.self, from: Data(line))
    }
}

final class GuestReports: Sendable {
    private let reader = Mutex(GuestReportReader())

    /// True when this brings a report after none, as when the agent starts.
    func feed(_ data: Data) -> Bool {
        reader.withLock { reader in
            let now = Date()
            let hadReport = reader.report(at: now) != nil
            reader.feed(data, now: now)
            return !hadReport && reader.report(at: now) != nil
        }
    }

    var report: GuestReport? {
        reader.withLock { $0.report(at: Date()) }
    }
}
