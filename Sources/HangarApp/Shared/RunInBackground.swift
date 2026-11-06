import Foundation

@concurrent
nonisolated func runInBackground<T>(_ work: @Sendable () throws -> sending T) async rethrows -> sending T {
    try work()
}
