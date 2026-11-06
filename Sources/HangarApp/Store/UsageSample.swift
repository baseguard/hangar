import Foundation

nonisolated struct UsageSample: Identifiable, Hashable, Sendable {
    let date: Date
    let cpu: Double
    let memory: UInt64
    let guestMemory: UInt64?
    let diskRead: Double
    let diskWrite: Double

    var id: Date { date }
}
