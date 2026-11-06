import AppKit
import Foundation
import HangarKit
import Virtualization

@MainActor
final class Runner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The window takes at most this much of the screen, and a quit waits this long for the VM to stop.
    private static let screenShare: CGFloat = 0.9
    private static let terminateWait = Duration.seconds(60)

    enum Mode {
        case window
        case headless
        case console
    }

    private let session: VMSession
    private let mode: Mode
    private var window: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private var stopRequested = false

    static func run(_ session: VMSession, mode: Mode) -> Never {
        let runner = Runner(session: session, mode: mode)
        // NSApplication keeps its delegate weakly; this frame never returns, so it keeps the runner alive.
        withExtendedLifetime(runner) { runner.start() }
    }

    private init(session: VMSession, mode: Mode) {
        self.session = session
        self.mode = mode
    }

    private func start() -> Never {
        // In the background stdout is the VM's log, which `hangar logs --follow` reads while the VM runs.
        setvbuf(stdout, nil, _IOLBF, 0)
        session.didStop = { [mode, session] error in Self.reportStopAndExit(of: session, mode: mode, error: error) }
        installSignalHandlers()
        if mode == .console {
            RawTerminal.enable()
        }

        Task {
            // A failed start was reported by didStop, which also ends the process.
            guard (try? await session.start()) != nil else { return }
            if mode != .console {
                print("'\(session.name)' is running (pid \(getpid())). Ctrl+C to shut it down.")
                await reportIP()
            }
        }

        guard mode == .window else { dispatchMain() }
        runWindow()
    }

    private static func reportStopAndExit(of session: VMSession, mode: Mode, error: Error?) {
        RawTerminal.restore()
        if let error {
            printError("'\(session.name)' stopped: \(error.localizedDescription)")
        } else if mode != .console {
            print("'\(session.name)' stopped.")
        }
        Task {
            // Lets the last lines reach the terminal before the process goes.
            try? await Task.sleep(for: .milliseconds(300))
            Foundation.exit(error == nil ? 0 : 1)
        }
    }

    private func runWindow() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.mainMenu = makeMenu()
        openWindow()
        app.activate()
        app.run()
        Foundation.exit(0)
    }

    func stop() {
        let isFirstRequest = !stopRequested
        // Marked before the request is awaited, so a second Ctrl+C during it forces the VM off.
        stopRequested = true
        Task {
            if isFirstRequest, (try? await session.requestStop()) != nil {
                if mode != .console { print("Asking the guest to shut down… (again to force off)") }
                return
            }
            do {
                try await session.forceStop()
            } catch {
                printError(error.localizedDescription)
            }
        }
    }

    /// A guest that takes longer than this to get an address is left to `hangar ip`.
    private static let ipWait: TimeInterval = 60

    private func reportIP() async {
        let config = session.config
        guard config.network.mode != .none else { return }
        if let ip = await IPResolver.waitForAddress(for: config, startedAt: Date(), timeout: Self.ipWait) {
            print("IP address: \(ip)")
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func openWindow() {
        let view = VZVirtualMachineView()
        view.virtualMachine = session.virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = session.config.followsWindowSize

        let display = session.config.guestDisplay
        // macOS guests draw at Retina scale, so their window shows the display at half its pixels.
        let scale: CGFloat = session.config.os == .macOS ? 2 : 1
        var size = NSSize(width: CGFloat(display.width) / scale, height: CGFloat(display.height) / scale)
        if let screen = NSScreen.main?.visibleFrame.size {
            let fit = min(
                1, screen.width * Self.screenShare / size.width, screen.height * Self.screenShare / size.height)
            size = NSSize(width: size.width * fit, height: size.height * fit)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(session.name) — Hangar"
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(Self.submenu("Hangar", Self.appItems()))
        menu.addItem(Self.submenu("Virtual Machine", Self.vmItems()))
        let window = Self.submenu("Window", Self.windowItems())
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    private static func appItems() -> [NSMenuItem] {
        [
            menuItem("Hide Hangar", #selector(NSApplication.hide(_:)), "h"),
            menuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            menuItem("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            menuItem("Quit Hangar", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private static func vmItems() -> [NSMenuItem] {
        [
            menuItem("Shut Down", #selector(Runner.shutDownVM), "."),
            menuItem("Stop Now", #selector(Runner.forceStopVM), ".", [.command, .option]),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        [
            menuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            menuItem("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            menuItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for menuItem in items {
            menu.addItem(menuItem)
        }
        item.submenu = menu
        return item
    }

    private static func menuItem(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func shutDownVM() {
        stopRequested = false
        stop()
    }

    @objc private func forceStopVM() {
        Task {
            do {
                try await session.forceStop()
            } catch {
                printError(error.localizedDescription)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stop()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop()
        Task {
            try? await Task.sleep(for: Self.terminateWait)
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }
}
