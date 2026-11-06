import AppKit
import SwiftUI
import Virtualization

struct LiveScreen: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> PreviewScreenView {
        let view = PreviewScreenView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = false
        return view
    }

    func updateNSView(_ view: PreviewScreenView, context: Context) {
        if view.virtualMachine !== virtualMachine { view.virtualMachine = virtualMachine }
    }
}

final class PreviewScreenView: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { false }
    override func mouseEntered(with event: NSEvent) { nextResponder?.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { nextResponder?.mouseExited(with: event) }
    override func mouseMoved(with event: NSEvent) { nextResponder?.mouseMoved(with: event) }
}
