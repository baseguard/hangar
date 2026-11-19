import Foundation

/// Runs `work` from the main run loop rather than as main-queue work. An alert or a quit started inside main-queue
/// work, like a main-actor task after an await, runs a nested run loop that doesn't serve the main queue: every other
/// main-actor task waits until the alert closes, and a quit that waits for one, as with VMs running, never ends.
@MainActor
func onMainRunLoop(_ work: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(work) }
}
