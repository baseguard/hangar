import SwiftUI

struct PageCommands: View {
    @Environment(VMStore.self) private var store
    @FocusedValue(\.selectedVM) private var name

    var body: some View {
        ForEach(Array(VMDetailView.Page.allCases.enumerated()), id: \.element) { index, page in
            Button(page.rawValue) { show(page) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(store.vm(name) == nil)
        }
        Divider()
    }

    private func show(_ page: VMDetailView.Page) {
        guard let name else { return }
        store.ask(.page(vm: name, page: page))
    }
}
