import HangarTraffic
import SwiftUI

struct TrafficRuleMenu: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let hosts: [String]

    var body: some View {
        let names = Array(Set(hosts.filter { (try? TrafficRule($0)) != nil })).sorted()
        if names.count == 1, let name = names.first {
            Button("Allow \(name)") { store.allowTraffic(to: names, in: vm.name) }
            Button("Block \(name)") { store.blockTraffic(to: names, in: vm.name) }
            Divider()
            Button("Copy \(name)") { Pasteboard.copy(name) }
        } else if !names.isEmpty {
            Button("Allow \(names.count) Hosts") { store.allowTraffic(to: names, in: vm.name) }
            Button("Block \(names.count) Hosts") { store.blockTraffic(to: names, in: vm.name) }
        }
    }
}
