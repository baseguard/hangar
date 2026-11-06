import HangarKit
import SwiftUI

struct ContentView: View {
    /// The narrowest window whose toolbar fits beside the sidebar; the sidebar hides only when the user hides it.
    static let minimumSize = CGSize(width: 980, height: 540)
    static let idealSize = CGSize(width: 1240, height: 800)
    static let screenFraction: CGFloat = 0.8

    @Environment(VMStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("lastSelectedVM") private var lastSelected = ""
    @State private var selection: SidebarItem?
    @State private var newVM: NewVMRequest?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(selection: $selection) { newVM = NewVMRequest() }
        } detail: {
            FillLayout { detail }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .sheet(item: $newVM) { request in
            CreateVMView(kind: request.kind, template: request.template) { id in selection = .job(id) }
        }
        .modifier(StoreAlerts())
        .modifier(LibraryDialogs())
        .modifier(SelectionFollowing(selection: $selection, lastSelected: $lastSelected, newVM: $newVM))
        .focusedSceneValue(\.selectedVM, selectedVM)
        .onAppear {
            MainWindow.open = openWindow
            // The library may have been scanned only every 10 s while no window was open.
            store.refresh()
            // Files shared while Hangar was starting arrived before any window could open the picker.
            if store.dropRequest != nil { DropWindow.show() }
        }
        .onChange(of: store.request?.id, initial: true) { showRequestedPage() }
    }

    private var selectedVM: String? {
        if case .vm(let name) = selection { name } else { nil }
    }

    @ContentBuilder
    private var detail: some View {
        if case .vm(let name) = selection, store.vm(name) != nil {
            VMDetailView(name: name).id(name)
        } else {
            placeholder
        }
    }

    @ContentBuilder
    private var placeholder: some View {
        switch selection {
        case .job(let id):
            if let job = store.jobs.first(where: { $0.id == id }) {
                JobView(job: job) { selection = $0.map(SidebarItem.job) }
            } else {
                ProgressView().controlSize(.large)
            }
        case .network:
            NetworkView()
        case .vm, nil:
            WelcomeView { newVM = NewVMRequest(kind: $0) }
        }
    }

    /// The VM's detail view takes the request itself when it appears.
    private func showRequestedPage() {
        guard case .page(let vm, _)? = store.request?.kind, selectedVM != vm else { return }
        selection = .vm(vm)
    }
}
