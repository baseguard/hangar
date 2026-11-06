import HangarKit
import HangarTraffic
import SwiftUI

extension VMStore {
    func allowTraffic(to hosts: [String], in name: String) {
        updateTraffic(name) { try $0.allow(hosts) }
    }

    func blockTraffic(to hosts: [String], in name: String) {
        updateTraffic(name) { try $0.block(hosts) }
    }

    func trafficBinding(_ vm: VMItem, _ keyPath: WritableKeyPath<TrafficPolicy, Bool> & Sendable) -> Binding<Bool> {
        Binding(
            get: { vm.config.traffic[keyPath: keyPath] },
            set: { value in self.updateTraffic(vm.name) { $0[keyPath: keyPath] = value } }
        )
    }
}
