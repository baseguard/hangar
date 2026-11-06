import HangarKit
import HangarTraffic
import SwiftUI

struct OverviewPage: View, Equatable {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let activity: TrafficActivity
    let show: (VMDetailView.Page) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.openSpacing) {
                hero
                if vm.isRunning {
                    UsageTiles(vm: vm)
                }
                CardGrid(minColumnWidth: Self.minimumCardWidth, maxColumns: 2, spacing: Metrics.bezelSpacing) {
                    ResourcesCard(vm: vm) { show(.settings) }
                    TrafficCard(vm: vm, activity: activity) { show(.traffic) }
                }
            }
            .scenePadding()
            .frame(maxWidth: Self.maximumWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    static let minimumCardWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 1180
    static let previewWidth: CGFloat = 300

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.vm == rhs.vm && lhs.activity == rhs.activity
    }

    private var hero: some View {
        HeroLayout(previewWidth: Self.previewWidth, spacing: Metrics.openSpacing) {
            ScreenPreview(vm: vm)
            heroInfo
        }
    }

    private var heroInfo: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            VStack(alignment: .leading) {
                HStack(alignment: .center, spacing: Metrics.spacing) {
                    Text(vm.name)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    StatusPill(phase: vm.phase)
                }
                Text(vm.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: Metrics.spacing) {
                ConnectionChips(vm: vm)
            }
            HeroActions(vm: vm)
            if let note {
                Notice(text: note)
            }
        }
    }

    private var note: String? {
        if let provisioning = vm.config.provisioning {
            return "The account “\(provisioning.username)” is created on the first start."
        }
        if vm.isRunning, store.sessions[vm.name] == nil {
            return vm.config.os == .windows
                ? "Started without a window. Use Remote Desktop to see its screen."
                : "Started without a window. Connect over SSH, or shut it down and start it here to see its screen."
        }
        return nil
    }
}
