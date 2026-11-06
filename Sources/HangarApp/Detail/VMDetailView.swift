import AppKit
import HangarKit
import HangarTraffic
import SwiftUI

struct VMDetailView: View {
    nonisolated enum Page: String, CaseIterable, Identifiable, Sendable {
        case overview = "Overview"
        case traffic = "Traffic"
        case secrets = "Secrets"
        case snapshots = "Snapshots"
        case settings = "Settings"

        var id: String { rawValue }
    }

    @Environment(VMStore.self) private var store
    @State private var model: DetailModel
    let name: String

    init(name: String) {
        self.name = name
        _model = State(initialValue: DetailModel())
    }

    var body: some View {
        if let vm = store.vm(name) {
            FillLayout {
                PageStack(vm: vm, model: model, pages: Page.allCases)
            }
            .clipped()
            .navigationTitle(vm.name)
            .navigationSubtitle(subtitle(vm))
            .toolbar { toolbar(vm) }
            .trafficActivity(of: vm.bundle, into: Bindable(model).activity)
            .onChange(of: store.request?.id, initial: true) {
                guard case .page(vm.name, let page)? = store.request?.kind else { return }
                store.request = nil
                model.page = page
            }
        }
    }

    private func subtitle(_ vm: VMItem) -> String {
        if let update = store.agentUpdates[vm.name] { return update.status(vm: vm.name) }
        if store.startingNetwork.contains(vm.name) { return "Starting the network…" }
        guard vm.isRunning, store.sessions[vm.name] == nil else { return vm.phase.title }
        return "\(vm.phase.title) \(vm.run?.host == .cli ? "in the background" : "elsewhere")"
    }

    @ToolbarContentBuilder
    private func toolbar(_ vm: VMItem) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            PagePicker(model: model, pages: Page.allCases)
        }
        .visibilityPriority(.high)
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isRunning {
                RunningControls(vm: vm) { VMDialog.stop(vm.name).post() }
            } else {
                VMStartButton(vm: vm)
                    .buttonStyle(.glassProminent)
            }
        }
        .visibilityPriority(.high)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            moreMenu(vm)
        }
        .visibilityPriority(.low)
    }

    private func moreMenu(_ vm: VMItem) -> some View {
        FilesAndMoreMenu(vm: vm, title: "More") {
            if vm.isRunning {
                Section {
                    VMConnectActions(vm: vm)
                }
            }
            VMManageActions(vm: vm, managesLibrary: true)
        }
    }
}

private struct PagePicker: View {
    @Bindable var model: DetailModel
    let pages: [VMDetailView.Page]

    var body: some View {
        Picker("Page", selection: $model.page) {
            ForEach(pages) { page in
                Text(page.rawValue).tag(page)
            }
        }
        .pickerStyle(.tabs)
        .labelsHidden()
        .fixedSize()
    }
}

private struct PageStack: View {
    let vm: VMItem
    let model: DetailModel
    let pages: [VMDetailView.Page]

    var body: some View {
        ZStack {
            ForEach(pages) { candidate in
                if candidate == model.page || model.visited.contains(candidate) {
                    let shown = candidate == model.page
                    page(candidate)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
            }
        }
        .environment(model)
    }

    @ContentBuilder
    private func page(_ candidate: VMDetailView.Page) -> some View {
        switch candidate {
        case .overview:
            OverviewPage(vm: vm, activity: model.activity, show: { model.page = $0 })
                .equatable()
        case .traffic:
            TrafficPage(vm: vm, activity: model.activity)
                .equatable()
        case .secrets:
            SecretsPage(vm: vm)
        case .snapshots:
            SnapshotsPage(vm: vm)
        case .settings:
            SettingsPage(vm: vm)
        }
    }
}
