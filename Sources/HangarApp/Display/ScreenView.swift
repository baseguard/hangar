import AppKit
import Carbon.HIToolbox
import Virtualization

/// The VM's screen. While it has the keyboard, keys the Mac would keep, like ⌘Tab, go to the guest too, and the pointer
/// stays on the screen; ⌃⌥⌘ gives both back to the Mac, and a click on the screen takes them again.
final class ScreenView: VZVirtualMachineView {
    typealias DropHandler = ([URL]) -> Void

    /// What the guest has of the Mac's input; the pointer only with the Accessibility permission.
    enum Capture: Equatable {
        case released
        case keyboard
        case keyboardAndPointer
    }

    static let releaseKeys: NSEvent.ModifierFlags = [.control, .option, .command]
    /// More than the strip at the top of a full screen that brings back the menu bar; Quartz's top edge is `minY`.
    private static let fullScreenTopMargin: CGFloat = 4
    /// macOS's alert for the permission comes once a launch; after that the window offers System Settings.
    private static var hasAskedForAccessibility = false

    var dropFiles: DropHandler?
    var captureChanged: ((Capture) -> Void)?
    private(set) var capture = Capture.released {
        didSet {
            if capture != oldValue { captureChanged?(capture) }
        }
    }
    var hasKeyboard: Bool { capture != .released }
    /// Sends the guest the releases AppKit keeps back while the guest has the keyboard.
    private var keyUpMonitor: Any?
    private let pointerFence = PointerFence()
    /// Hangar leaving the front gives the input back, so no other app ever finds it held; moving or resizing the
    /// window moves the pointer's fence with it.
    private var windowObservers: [NotificationCenter.ObservationToken] = []
    /// A window resizes from its edges and corners, which the held pointer reaches, so it doesn't while held.
    private var resizingWasAllowed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    func captureKeyboard() {
        capturesSystemKeys = true
        window?.makeFirstResponder(self)
        if window?.firstResponder === self, !hasKeyboard { holdInput() }
    }

    /// The guest still gets the release keys' own presses; leaving first responder makes the view lift them again.
    func releaseKeyboard() {
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            capturesSystemKeys = false
            letInputGo()
        }
        return didResign
    }

    override func mouseDown(with event: NSEvent) {
        if !hasKeyboard { captureKeyboard() }
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { letInputGo() }
    }

    /// The pointer moves as macOS moves it but can't leave the VM's screen. That takes the Accessibility permission;
    /// without it, only the keyboard is held.
    private func holdInput() {
        guard let window else { return }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return keyUpGoingToGuest(event)
        }
        windowObservers = observe(window)
        capture = holdPointer() ? .keyboardAndPointer : .keyboard
    }

    private func holdPointer() -> Bool {
        guard PointerFence.isAllowed else {
            if !Self.hasAskedForAccessibility { PointerFence.askForPermission() }
            Self.hasAskedForAccessibility = true
            return false
        }
        moveFence()
        guard pointerFence.start() else { return false }
        stopResizing()
        return true
    }

    /// A full-screen window has no edges to resize from.
    private func stopResizing() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        resizingWasAllowed = window.styleMask.contains(.resizable)
        window.styleMask.remove(.resizable)
    }

    private func allowResizingAgain() {
        if resizingWasAllowed { window?.styleMask.insert(.resizable) }
        resizingWasAllowed = false
    }

    private func letInputGo() {
        guard let keyUpMonitor else { return }
        NSEvent.removeMonitor(keyUpMonitor)
        self.keyUpMonitor = nil
        pointerFence.stop()
        allowResizingAgain()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        capture = .released
    }

    private func observe(_ window: NSWindow) -> [NotificationCenter.ObservationToken] {
        let center = NotificationCenter.default
        return [
            center.addObserver(of: NSApplication.self, for: .didResignActive) { [weak self] _ in
                self?.releaseKeyboard()
            },
            center.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.releaseKeyboard() },
            center.addObserver(of: window, for: .didMove) { [weak self] _ in self?.moveFence() },
            center.addObserver(of: window, for: .didResize) { [weak self] _ in self?.moveFence() },
            center.addObserver(of: window, for: .didChangeScreen) { [weak self] _ in self?.moveFence() },
            center.addObserver(of: window, for: .didEnterFullScreen) { [weak self] _ in self?.moveFence() },
            center.addObserver(of: window, for: .didExitFullScreen) { [weak self] _ in self?.moveFence() },
        ]
    }

    /// The VM's screen on the Mac's screen, where the pointer stays while it is held.
    private func moveFence() {
        guard let window else { return }
        let screen = NSScreen.quartzRect(window.convertToScreen(convert(bounds, to: nil)))
        pointerFence.fence(in: window.styleMask.contains(.fullScreen) ? Self.belowTopEdge(screen) : screen)
    }

    /// In full screen macOS brings back the menu bar and the window's title and controls while the pointer rests at
    /// the top edge; a held pointer stays just below it, so they come back only once the shortcut lets it go.
    private static func belowTopEdge(_ screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX, y: screen.minY + fullScreenTopMargin, width: screen.width,
            height: screen.height - fullScreenTopMargin)
    }

    /// AppKit never delivers the release of a key pressed with ⌘, so it goes to the guest from here, or the key would
    /// stay down in the guest.
    private func keyUpGoingToGuest(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.modifierFlags.contains(.command) else { return event }
        keyUp(with: event)
        return nil
    }

    /// Virtualization's view leaves key equivalents to the menus, so ⌘Q or ⌘W would reach Hangar; while the guest has
    /// the keyboard they go to the guest like any other key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasKeyboard else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let held = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard hasKeyboard, held == Self.releaseKeys else { return }

        liftReleaseKeysInGuest(like: event)
        releaseKeyboard()
    }

    /// The guest saw ⌃⌥⌘ go down, but the Mac gets their release; left and right keys both go up, since either may be
    /// held.
    private func liftReleaseKeysInGuest(like event: NSEvent) {
        let steps: [(keyCode: UInt16, stillHeld: NSEvent.ModifierFlags)] = [
            (UInt16(kVK_Command), [.control, .option]), (UInt16(kVK_RightCommand), [.control, .option]),
            (UInt16(kVK_Option), [.control]), (UInt16(kVK_RightOption), [.control]), (UInt16(kVK_Control), []),
            (UInt16(kVK_RightControl), []),
        ]
        for step in steps {
            guard
                let keyUp = NSEvent.keyEvent(
                    with: .flagsChanged, location: event.locationInWindow, modifierFlags: step.stillHeld,
                    timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: step.keyCode)
            else { continue }
            super.flagsChanged(with: keyUp)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls =
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let dropFiles else { return false }
        dropFiles(urls)
        return true
    }
}
