import HangarSupport

extension FileLock {
    private static let retryInterval = Duration.milliseconds(500)

    /// Waits while another Hangar process holds the lock, telling the user what it waits for.
    func lockWaiting(_ phase: String, progress: ProgressHandler) async throws {
        while try !tryLock(.exclusive) {
            progress(CreationProgress(phase: phase))
            try await Task.sleep(for: Self.retryInterval)
        }
    }
}
