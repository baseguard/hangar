import SwiftUI
import Virtualization

struct VirtualMachineScreen: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let fixedSize: CGSize?
    let dropFiles: ScreenView.DropHandler
    let captureChanged: (ScreenView.Capture) -> Void

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.virtualMachine = virtualMachine
        view.dropFiles = dropFiles
        view.captureChanged = captureChanged
        view.automaticallyReconfiguresDisplay = fixedSize == nil
        // The view has no window until SwiftUI has placed it, a turn of the run loop later.
        Task {
            guard let window = view.window else { return }
            view.captureKeyboard()
            if let fixedSize {
                let toolbarHeight = window.frame.height - window.contentLayoutRect.height
                window.setContentSize(CGSize(width: fixedSize.width, height: fixedSize.height + toolbarHeight))
            }
        }
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
        view.dropFiles = dropFiles
        view.captureChanged = captureChanged
    }
}
