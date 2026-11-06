import HangarKit
import SwiftUI
import Virtualization

struct DisplayView: View {
    static let minimumSize = CGSize(width: 640, height: 400)
    static let idealSize = CGSize(width: 1280, height: 820)
    static let screenFraction: CGFloat = 0.9

    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var stopping: String?
    let name: String

    var body: some View {
        DisplayContent(name: name)
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
            .navigationTitle(name)
            .navigationSubtitle(
                store.agentUpdates[name]?.status(vm: name) ?? store.dropStatus[name]
                    ?? store.sessions[name]?.setupStatus ?? store.vm(name)?.phase.title ?? ""
            )
            .sheet(item: copyInProgress) { copy in
                CopyProgressSheet(copy: copy) { store.cancelCopy(into: name) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.dropFiles(urls, into: name)
            }
            .focusedSceneValue(\.selectedVM, name)
            .onAppear { MainWindow.open = openWindow }
            .toolbar {
                if let vm = store.vm(name), vm.isRunning {
                    ToolbarItemGroup(placement: .primaryAction) {
                        RunningControls(vm: vm) { stopping = name }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    FilesAndMoreMenu(vm: store.vm(name), title: "Virtual Machine") {
                        VMCommands(name: name)
                    }
                }
            }
            // In full screen the guest gets the whole screen; the title and controls come back at the top edge.
            .windowToolbarFullScreenVisibility(.onHover)
            .modifier(ForceStopConfirmation(stopping: $stopping))
            .modifier(StoreAlerts())
            .modifier(ClosesWhenVMIsGone(name: name, windowID: DisplayWindow.id))
    }

    private var copyInProgress: Binding<FileCopy?> {
        Binding(get: { store.copies[name] }, set: { if $0 == nil { store.cancelCopy(into: name) } })
    }
}

private struct DisplayContent: View {
    @Environment(VMStore.self) private var store
    @State private var keyboardHint: KeyboardHint?
    @State private var capture = ScreenView.Capture.released
    let name: String

    var body: some View {
        if let session = store.sessions[name] {
            VirtualMachineScreen(
                virtualMachine: session.virtualMachine,
                fixedSize: session.config.followsWindowSize
                    ? nil
                    : CGSize(width: session.config.guestDisplay.width, height: session.config.guestDisplay.height),
                dropFiles: { urls in store.dropFiles(urls, into: name) },
                captureChanged: { changed in
                    capture = changed
                    keyboardHint = KeyboardHint(capture: changed)
                }
            )
            .overlay(alignment: .bottom) {
                if let keyboardHint {
                    KeyboardHintLabel(hint: keyboardHint) { self.keyboardHint = nil }
                }
            }
            .overlay {
                if session.state != .running {
                    StatusOverlay(state: session.state)
                }
            }
            .overlay(alignment: .top) {
                if session.state == .running, store.usage[name]?.hasScreen == false {
                    NoScreenBanner()
                } else if capture == .keyboard {
                    AccessibilityBanner()
                }
            }
        } else if let vm = store.vm(name), vm.isRunning {
            ContentUnavailableView {
                Label("Running Without a Window", systemImage: "rectangle.dashed")
            } description: {
                Text(
                    "“\(name)” was started in the background, so its screen isn't available here. Shut it down and start it in Hangar to see it."
                )
            } actions: {
                Button("Shut Down") { store.shutdown(name) }
            }
        } else {
            ContentUnavailableView {
                Label("“\(name)” Isn't Running", systemImage: "power")
            } actions: {
                StartButton(name: name)
            }
        }
    }
}

private struct StartButton: View {
    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let name: String

    var body: some View {
        Button("Start") { store.start(name) { openWindow(id: DisplayWindow.id, value: $0) } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.busy.contains(name))
    }
}

private struct StatusOverlay: View {
    /// A paused screen stays readable; a busy one is covered.
    private static let pausedDim = 0.35
    private static let busyDim = 0.6

    let state: VZVirtualMachine.State

    var body: some View {
        ZStack {
            Color.black.opacity(state == .paused ? Self.pausedDim : Self.busyDim)
            HStack {
                if state == .paused {
                    Image(systemName: "pause.fill")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(state.name.capitalized + (state == .paused ? "" : "…"))
            }
            .font(.title3.weight(.medium))
            .padding(.horizontal, Metrics.controlInset)
            .frame(height: Metrics.extraLargeControlSize)
            .glassEffect(.regular, in: .capsule)
        }
        .allowsHitTesting(state != .paused)
    }
}

/// Each change of who has the keyboard is a new hint, so the same text shown again starts its time again.
private struct KeyboardHint: Equatable {
    let id = UUID()
    let capture: ScreenView.Capture
}

/// Says how to give the keyboard back, or take it again, for a few seconds after either happens.
private struct KeyboardHintLabel: View {
    static let duration = Duration.seconds(3)

    let hint: KeyboardHint
    let hide: () -> Void

    var body: some View {
        Label(text, systemImage: "keyboard")
            .padding(Metrics.controlInset)
            .glassEffect(.regular, in: .capsule)
            .padding(Metrics.bezelSpacing)
            .allowsHitTesting(false)
            .task(id: hint.id) {
                try? await Task.sleep(for: Self.duration)
                if !Task.isCancelled { hide() }
            }
    }

    private var text: String {
        switch hint.capture {
        case .keyboardAndPointer: "Press ⌃⌥⌘ to give the keyboard and pointer back to your Mac"
        case .keyboard: "Press ⌃⌥⌘ to give the keyboard back to your Mac"
        case .released: "Click the screen to use the VM again"
        }
    }
}

/// Without the permission the pointer can leave the VM's screen while the guest has the keyboard.
private struct AccessibilityBanner: View {
    var body: some View {
        HStack {
            Label(
                "To keep the pointer on the VM's screen, allow Hangar in Accessibility, then click the screen again.",
                systemImage: "cursorarrow.motionlines")
            Button("Open System Settings") {
                if let url = PointerFence.settingsURL { NSWorkspace.shared.open(url) }
            }
        }
        .padding(Metrics.controlInset)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cornerRadius))
        .padding(Metrics.bezelSpacing)
    }
}

/// Without it, a guest whose kernel draws nothing after the startup screen looks stuck.
private struct NoScreenBanner: View {
    var body: some View {
        Label(
            "This Linux has no screen driver, so the window stays on the startup screen. The VM is running; reach it with hangar exec or SSH.",
            systemImage: "display.trianglebadge.exclamationmark"
        )
        .padding(Metrics.controlInset)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cornerRadius))
        .padding(Metrics.bezelSpacing)
    }
}
