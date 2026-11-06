import SwiftUI

/// The toolbar's More menu. While the VM runs it is a split button, like Shut Down: a click opens the VM's files and
/// the arrow opens the menu.
struct FilesAndMoreMenu<Items: View>: View {
    @Environment(\.openWindow) private var openWindow
    let vm: VMItem?
    let title: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        if let vm, vm.isRunning {
            Menu(content: items) {
                Label("Browse Files", systemImage: "folder")
            } primaryAction: {
                openWindow(id: FilesWindow.id, value: vm.name)
            }
            .help("Browse Files")
        } else {
            Menu(content: items) {
                Label(title, systemImage: "ellipsis")
            }
            .help(title)
        }
    }
}
