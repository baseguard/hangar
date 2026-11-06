import Synchronization

final class FrameRelay: Sendable {
    /// A class rather than the bare closure: a closure stored in the Mutex and read back out gets a new
    /// reabstraction thunk around it each time, until delivering a frame overflows the stack.
    private final class Handler: Sendable {
        let deliver: @Sendable ([UInt8]) -> Void

        init(_ deliver: @escaping @Sendable ([UInt8]) -> Void) {
            self.deliver = deliver
        }
    }

    private let handler = Mutex<Handler?>(nil)

    func connect(_ deliver: @escaping @Sendable ([UInt8]) -> Void) {
        let connected = Handler(deliver)
        handler.withLock { $0 = connected }
    }

    func deliver(_ frame: [UInt8]) {
        handler.withLock { $0 }?.deliver(frame)
    }
}
