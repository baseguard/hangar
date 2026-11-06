import HangarKit
import HangarTraffic
import SwiftUI

struct TrafficRuleSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let host: String

    var body: some View {
        if (try? TrafficRule(host)) != nil {
            Section {
                HStack {
                    Button("Allow") { store.allowTraffic(to: [host], in: vm.name) }
                    Button("Block") { store.blockTraffic(to: [host], in: vm.name) }
                    Spacer()
                    Button("Copy") { Pasteboard.copy(host) }
                }
                .disabled(vm.config.network.mode != .managed)
            } footer: {
                Text("Adds \(host) to the VM's allow or block list.")
            }
        }
    }
}
