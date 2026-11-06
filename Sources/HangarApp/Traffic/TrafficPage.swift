import HangarKit
import HangarTraffic
import SwiftUI

struct TrafficPage: View, Equatable {
    static let minimumHeaderWidth: CGFloat = 240
    static let filterWidth: ClosedRange<CGFloat> = 110...220

    let vm: VMItem
    let activity: TrafficActivity

    @Environment(DetailModel.self) private var model
    @State private var search = ""
    @State private var blockedOnly = false
    @AppStorage("trafficDetailsWidth") private var detailsWidth = Double(Metrics.detailsWidth)
    @State private var resizeStart: Double?
    @State private var pageWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TrafficPolicyBar(vm: vm)
            if vm.config.network.mode != .managed {
                UnwatchedTrafficNotice()
            }
            Divider()
            HStack(spacing: 0) {
                TrafficList(vm: vm, activity: activity, model: model, search: $search, blockedOnly: $blockedOnly)
                    .frame(minWidth: 0)
                if model.trafficDetailsShown {
                    Divider()
                        .overlay { resizeHandle }
                    TrafficDetailsPanel(vm: vm, model: model)
                        .frame(width: panelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.trafficDetailsShown)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                pageWidth = $0
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.connectionSelection) {
            if !model.connectionSelection.isEmpty { model.showsTrafficDetails = true }
        }
        .onChange(of: model.lookupSelection) { if !model.lookupSelection.isEmpty { model.showsTrafficDetails = true } }
    }

    private var panelWidth: CGFloat {
        min(max(CGFloat(detailsWidth), Metrics.detailsWidth), max(Metrics.detailsWidth, pageWidth / 2))
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: Metrics.spacing)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = resizeStart ?? Double(panelWidth)
                        resizeStart = start
                        detailsWidth = start - value.translation.width
                    }
                    .onEnded { _ in
                        resizeStart = nil
                        detailsWidth = Double(panelWidth)
                    }
            )
            .accessibilityHidden(true)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.vm == rhs.vm && lhs.activity == rhs.activity
    }
}

private struct TrafficPolicyBar: View {
    let vm: VMItem

    var body: some View {
        AccessoryRow(minPrimaryWidth: TrafficPage.minimumHeaderWidth, spacing: Metrics.bezelSpacing) {
            HStack {
                Image(systemName: policy.symbol)
                    .font(.title2)
                    .foregroundStyle(policy.tint)
                    .frame(width: Metrics.controlSize)
                VStack(alignment: .leading) {
                    Text(policy.title).font(.headline)
                    Text(policy.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TrafficPolicyControls(vm: vm)
        }
        .scenePadding(.horizontal)
        .padding(.vertical, Metrics.bezelSpacing)
        .background(policy.tint.opacity(Metrics.bannerTint))
    }

    private var policy: (title: String, detail: String, symbol: String, tint: Color) {
        let traffic = vm.config.traffic
        if traffic.isolated {
            return (
                "Isolated", "The VM can't reach anything, and only this Mac can connect to it.", "network.slash", .red
            )
        }
        switch traffic.mode {
        case .off:
            return ("Not Watching", "Traffic isn't recorded. Choose Monitor to record it.", "eye.slash", .secondary)
        case .monitor:
            return ("Monitoring", "Every connection and lookup is recorded. Nothing is blocked.", "eye", .accentColor)
        case .allowlist:
            let count = traffic.allowed.count
            return (
                "Allow List",
                count == 0
                    ? "Everything is blocked. Add the hosts the VM may reach under Rules."
                    : "Only \(count) allowed \(counted(count, "host")) can be reached; everything else is blocked.",
                "checkmark.shield", .green
            )
        case .blocklist:
            let count = traffic.blocked.count
            return (
                "Block List",
                count == 0
                    ? "Nothing is blocked yet. Add hosts to block under Rules."
                    : "\(count) \(counted(count, "host")) \(count == 1 ? "is" : "are") blocked; everything else is allowed.",
                "xmark.shield", .orange
            )
        }
    }
}

private struct TrafficPolicyControls: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        HStack {
            Picker(
                "Mode",
                selection: Binding(
                    get: { vm.config.traffic.mode },
                    set: { mode in store.updateTraffic(vm.name) { $0.mode = mode } }
                )
            ) {
                ForEach(TrafficPolicy.Mode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(
                "Monitor records everything; Allow List blocks all but the allowed hosts; Block List blocks only the blocked ones"
            )
            Toggle(
                isOn: Binding(
                    get: { vm.config.traffic.isolated },
                    set: { isolated in store.updateTraffic(vm.name) { $0.isolated = isolated } }
                )
            ) {
                Label("Isolate", systemImage: "network.slash")
            }
            .toggleStyle(.button)
            .tint(.red)
            .fixedSize()
            .help("Cut the VM off the network at once; only this Mac can still connect to it")
        }
        .disabled(vm.config.network.mode != .managed)
    }
}

private struct UnwatchedTrafficNotice: View {
    var body: some View {
        Notice(
            text: "Hangar only sees the traffic of Hangar Managed VMs. Switch this VM to Hangar Managed in Settings.",
            systemImage: "eye.slash", tint: .orange
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .scenePadding(.horizontal)
        .padding(.vertical, Metrics.spacing)
        .background(Color.orange.opacity(Metrics.bannerTint))
    }
}

private struct TrafficList: View {
    let vm: VMItem
    let activity: TrafficActivity
    @Bindable var model: DetailModel
    @Binding var search: String
    @Binding var blockedOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            TrafficFilterBar(scope: $model.trafficScope, search: $search, blockedOnly: $blockedOnly)
            Divider()
            Group {
                switch model.trafficScope {
                case .connections:
                    ConnectionsTable(
                        vm: vm, rows: filtered(activity.connections),
                        selection: $model.connectionSelection
                    ) {
                        model.showsTrafficDetails = true
                    }
                case .hosts:
                    HostsTable(vm: vm, rows: filtered(activity.hosts))
                case .lookups:
                    LookupsTable(
                        vm: vm, rows: filtered(activity.lookups), selection: $model.lookupSelection
                    ) {
                        model.showsTrafficDetails = true
                    }
                case .rules: TrafficRulesForm(vm: vm, search: search)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            TrafficFooter(vm: vm, counts: counts, hasTraffic: activity.count > 0)
        }
    }

    private var counts: String {
        let lookups = activity.lookups.count
        return
            "\(activity.connections.count) \(counted(activity.connections.count, "connection")) · \(activity.hosts.count) \(counted(activity.hosts.count, "host")) · \(lookups) \(counted(lookups, "lookup")) · \(activity.blocked) blocked"
    }

    /// The rows as they are while nothing filters them, so a redraw doesn't walk thousands of rows for nothing.
    private func filtered<Row: TrafficRow>(_ rows: [Row]) -> [Row] {
        guard blockedOnly || !search.isEmpty else { return rows }
        return rows.filter(matchesFilter)
    }

    private func matchesFilter(_ row: some TrafficRow) -> Bool {
        (!blockedOnly || row.isBlocked) && (search.isEmpty || row.searchText.localizedCaseInsensitiveContains(search))
    }
}

/// The totals, and the button that saves the whole traffic log, its older files included.
private struct TrafficFooter: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let counts: String
    let hasTraffic: Bool

    var body: some View {
        HStack {
            Text(counts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Export Log…", systemImage: "square.and.arrow.up", action: export)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!hasTraffic)
                .help("Save the whole traffic log as a JSON Lines file, one event per line")
        }
        .scenePadding(.horizontal)
        .padding(.vertical, Metrics.spacing)
    }

    private func export() {
        guard let destination = FilePanels.chooseTrafficLogFile(for: vm.name) else { return }
        let log = vm.bundle.trafficLogURL
        Task {
            do {
                try await runInBackground { try TrafficLog.export(log, to: destination) }
            } catch {
                store.report(error, doing: "export the traffic log")
            }
        }
    }
}

private struct TrafficFilterBar: View {
    @Binding var scope: TrafficPage.Scope
    @Binding var search: String
    @Binding var blockedOnly: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            TrailingRow(spacing: Metrics.bezelSpacing, trailingWidth: TrafficPage.filterWidth) {
                ScopeControls(scope: $scope, blockedOnly: $blockedOnly, isCompact: false)
                FilterField(text: $search, prompt: "Filter")
            }
            VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
                ScopeControls(scope: $scope, blockedOnly: $blockedOnly, isCompact: false)
                FilterField(text: $search, prompt: "Filter")
                    .frame(maxWidth: TrafficPage.filterWidth.upperBound)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TrailingRow(spacing: Metrics.bezelSpacing, trailingWidth: TrafficPage.filterWidth) {
                ScopeControls(scope: $scope, blockedOnly: $blockedOnly, isCompact: true)
                FilterField(text: $search, prompt: "Filter")
            }
        }
        .scenePadding(.horizontal)
        .padding(.vertical, Metrics.spacing)
    }
}

private struct ScopeControls: View {
    @Binding var scope: TrafficPage.Scope
    @Binding var blockedOnly: Bool
    let isCompact: Bool

    var body: some View {
        HStack(spacing: Metrics.bezelSpacing) {
            if isCompact {
                scopePicker.pickerStyle(.menu)
            } else {
                scopePicker.pickerStyle(.segmented)
            }
            if scope != .rules {
                Toggle("Blocked Only", isOn: $blockedOnly)
                    .toggleStyle(.button)
                    .fixedSize()
            }
        }
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(TrafficPage.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct TrafficRulesForm: View {
    let vm: VMItem
    let search: String

    var body: some View {
        Form {
            TrafficRuleTransfer(vm: vm)
            TrafficRuleLists(vm: vm, filter: search)
        }
        .formStyle(.grouped)
        .disabled(vm.config.network.mode != .managed)
    }
}
