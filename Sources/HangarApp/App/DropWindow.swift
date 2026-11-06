import AppKit
import SwiftUI

/// The small window that asks where files shared to Hangar go. It has its own window so the main window, often
/// behind a VM's screen, isn't pulled forward with a sheet on it.
struct DropWindow: View {
    static let id = "drop"

    @Environment(VMStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if let request = store.dropRequest {
                DropPicker(request: request, close: close)
                    .id(request.id)
            }
        }
        .frame(width: ExportSheet.width)
        // A grouped form takes all the height it is given; the window follows the content instead, as a sheet did.
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: store.dropRequest?.id, initial: true) {
            if store.dropRequest == nil { close() }
        }
        // Closed with the window's close button too, so the next share starts over.
        .onDisappear { store.dropRequest = nil }
    }

    static func show() {
        MainWindow.open?(id: id)
        NSApp.activate()
    }

    private func close() {
        dismissWindow(id: Self.id)
    }
}
