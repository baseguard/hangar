import Foundation
import HangarSupport
import Synchronization

final class TransferCounter: Sendable {
    /// Progress goes out at most twice a second; the rate is over the last few seconds of samples.
    private static let reportInterval: TimeInterval = 0.5
    private static let rateWindow: TimeInterval = 5
    private static let shortestRateSample: TimeInterval = 1

    private struct State {
        var done: Int64
        var downloaded: Int64 = 0
        var lastReport = Date.distantPast
        /// When each report was made and how much had been downloaded by then, for the speed.
        var samples: [(Date, Int64)] = []
    }

    private let total: Int64
    private let phase: String
    private let progress: ProgressHandler
    private let state: Mutex<State>

    init(total: Int64, done: Int64, phase: String, progress: @escaping ProgressHandler) {
        self.total = total
        self.phase = phase
        self.progress = progress
        state = Mutex(State(done: done))
        report(force: true)
    }

    /// Bytes that arrived over the network; only these make the speed.
    func addDownloaded(_ bytes: Int64) {
        state.withLock { state in
            state.done += bytes
            state.downloaded += bytes
        }
        report(force: false)
    }

    /// Bytes that count toward the total without crossing the network, such as a whole part copied from another
    /// image on this Mac, a part file resumed from disk, or a part taken back to download again.
    func add(_ bytes: Int64) {
        state.withLock { $0.done += bytes }
        report(force: false)
    }

    private func report(force: Bool) {
        let now = Date()
        let update: CreationProgress? = state.withLock { state in
            guard force || now.timeIntervalSince(state.lastReport) >= Self.reportInterval else { return nil }
            state.lastReport = now
            state.samples.append((now, state.downloaded))
            state.samples.removeAll { now.timeIntervalSince($0.0) > Self.rateWindow }
            var detail = "\(ByteSize.format(UInt64(max(state.done, 0)))) of \(ByteSize.format(UInt64(total)))"
            if let first = state.samples.first, now.timeIntervalSince(first.0) >= Self.shortestRateSample {
                let rate = Double(state.downloaded - first.1) / now.timeIntervalSince(first.0)
                if rate > 0 { detail += " · \(ByteSize.format(UInt64(rate)))/s" }
            }
            return CreationProgress(
                phase: phase, fraction: total > 0 ? Double(state.done) / Double(total) : nil, detail: detail)
        }
        if let update { progress(update) }
    }
}
