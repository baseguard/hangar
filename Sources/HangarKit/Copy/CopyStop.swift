import Darwin
import Synchronization

/// Ends a copy from another thread, such as the app's Cancel. Shutting down the copy's connection wakes a read or
/// write that waits on a guest that stopped answering, which checking for cancellation between pieces can't.
package final class CopyStop: Sendable {
    private struct State {
        var descriptor: Int32?
        var isStopped = false
    }

    private let state = Mutex(State())

    package init() {}

    var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    package func stop() {
        state.withLock { state in
            state.isStopped = true
            if let descriptor = state.descriptor { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// The copy's connection from now on; one that opens after the stop is shut down at once.
    func watch(_ descriptor: Int32) {
        state.withLock { state in
            state.descriptor = descriptor
            if state.isStopped { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// Under the lock, so a stop can't shut down another connection that gets the descriptor's number next. The
    /// shutdown wakes a reader still waiting on it, such as the thread that waits for the agent's exit.
    func close(_ descriptor: Int32) {
        state.withLock { state in
            state.descriptor = nil
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
}
