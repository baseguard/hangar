import AppKit
import ApplicationServices
import Synchronization

/// Keeps the Mac's pointer inside an area while it is on: an event tap sees every move
/// before any app does and stops the pointer at the area's edge. The pointer itself moves as macOS moves it, at the
/// user's own speed. macOS lets an app filter events only with the Accessibility permission.
///
/// Each start runs a tap on a thread of its own, so a busy main thread never holds up the Mac's pointer, and its
/// callback only compares numbers, so macOS never turns it off for answering slowly.
nonisolated final class PointerFence: Sendable {
    /// In Quartz coordinates, the VM's screen; `nil` lets every move through.
    private let area = Mutex<CGRect?>(nil)
    /// A view owns one pair of its edges but not the other, and Quartz flips which: its top edge in Quartz is the
    /// toolbar's. Half a point in from every edge is always the view's, and still its outermost pixel on a Retina
    /// screen.
    private static let inset: CGFloat = 0.5
    /// Each start's tap runs while this is still its own; a stop or a newer start ends it.
    private let current = Atomic<Int>(0)

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// macOS's own alert, which leads to System Settings.
    static func askForPermission() {
        // The value of kAXTrustedCheckOptionPrompt, a global Swift 6 won't read outside the main actor.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Privacy & Security › Accessibility.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Moves with the window; the main thread sets it, the tap's thread reads it.
    func fence(in area: CGRect) {
        self.area.withLock { $0 = area.insetBy(dx: Self.inset, dy: Self.inset) }
    }

    /// False when macOS refuses the tap, such as without the permission.
    func start() -> Bool {
        let started = Mutex<Bool?>(nil)
        let ready = DispatchSemaphore(value: 0)
        let generation = current.add(1, ordering: .sequentiallyConsistent).newValue
        let thread = Thread {
            FenceTap.run(for: self, generation: generation) { isRunning in
                started.withLock { $0 = isRunning }
                ready.signal()
            }
        }
        thread.name = "io.baseguard.hangar.pointer-fence"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return started.withLock { $0 } ?? false
    }

    /// The pointer is free at once: the tap lets every move through from now on and ends with the next one.
    func stop() {
        current.add(1, ordering: .sequentiallyConsistent)
        area.withLock { $0 = nil }
    }

    fileprivate func isCurrent(_ generation: Int) -> Bool {
        current.load(ordering: .sequentiallyConsistent) == generation
    }

    /// Where a move that would leave the area ends instead: on its edge, so every pixel of the VM's screen can be
    /// reached and none past it.
    fileprivate func edge(for location: CGPoint) -> CGPoint? {
        guard let area = area.withLock({ $0 }) else { return nil }
        let fenced = CGPoint(
            x: min(max(location.x, area.minX), area.maxX), y: min(max(location.y, area.minY), area.maxY))
        return fenced == location ? nil : fenced
    }
}

/// One start's tap, made and used only on its own thread.
nonisolated private final class FenceTap {
    let fence: PointerFence
    let generation: Int
    var tap: CFMachPort?

    private init(fence: PointerFence, generation: Int) {
        self.fence = fence
        self.generation = generation
    }

    /// Runs the tap until it ends; `started` says at once whether macOS gave it one.
    static func run(for fence: PointerFence, generation: Int, started: (Bool) -> Void) {
        let owner = FenceTap(fence: fence, generation: generation)
        let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = moves.reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: fenceEvent, userInfo: Unmanaged.passUnretained(owner).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        else {
            started(false)
            return
        }

        owner.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        started(true)
        CFRunLoopRun()
        withExtendedLifetime(owner) {}
    }

    /// macOS turns a tap off when it misses a deadline or the user presses a secure key combination; it goes back on.
    func handle(_ type: CGEventType, _ event: CGEvent) {
        guard fence.isCurrent(generation) else { return end() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let edge = fence.edge(for: event.location) else { return }
        event.location = edge
        CGWarpMouseCursorPosition(edge)
        // A warp holds back the next moves for a moment; reassociating right after lifts that.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func end() {
        guard let tap else { return }
        CFMachPortInvalidate(tap)
        self.tap = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

/// The tap's callback; it runs on the tap's thread.
nonisolated private func fenceEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, owner: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let owner { Unmanaged<FenceTap>.fromOpaque(owner).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}

extension NSScreen {
    /// Quartz counts from the top left of the main display, AppKit from its bottom left.
    static func quartzRect(_ rect: NSRect) -> CGRect {
        let mainHeight = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
