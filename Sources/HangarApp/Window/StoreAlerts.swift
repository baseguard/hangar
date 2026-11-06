import SwiftUI

struct StoreAlerts: ViewModifier {
    @Environment(VMStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    /// Taken while this window is active and kept until it's dismissed: the alert's own sheet makes the window
    /// look inactive, and letting go then closed every alert as soon as it opened.
    @State private var shown: StoreAlert?

    func body(content: Content) -> some View {
        let showing = Binding(
            get: { shown != nil },
            set: { isShowing in
                if !isShowing { dismissShown() }
            }
        )
        content.alert(shown?.title ?? "", isPresented: showing, presenting: shown) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: appearsActive, initial: true) { takeWaitingAlert() }
        .onChange(of: store.alert?.id) { takeWaitingAlert() }
    }

    /// Keeps the shown alert while it still waits; once another window has dismissed it, this one moves on.
    private func takeWaitingAlert() {
        let waiting = store.alert
        let isStillWaiting = shown != nil && shown?.id == waiting?.id
        guard !isStillWaiting else { return }

        shown = appearsActive ? waiting : nil
    }

    private func dismissShown() {
        guard let alert = shown else { return }
        shown = nil
        store.dismissAlert(alert.id)
    }
}
