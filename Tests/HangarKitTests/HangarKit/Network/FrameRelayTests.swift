import Synchronization
import Testing

@testable import HangarKit

struct FrameRelayTests {
    @Test func deliveringManyFramesKeepsTheHandlerFlat() {
        let relay = FrameRelay()
        let received = Mutex(0)
        relay.connect { frame in received.withLock { $0 += frame.count } }
        let frame = [UInt8](repeating: 0, count: 4)

        for _ in 0..<300_000 {
            relay.deliver(frame)
        }

        #expect(received.withLock { $0 } == 1_200_000)
    }
}
