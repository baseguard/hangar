import HangarKit
import SwiftUI

extension VMStore {
    /// A control's binding to one of a VM's settings; each change is saved through `update`.
    func binding<Value: Sendable>(
        _ keyPath: WritableKeyPath<VMConfig, Value> & Sendable, of vm: VMItem
    ) -> Binding<Value> {
        Binding(
            get: { vm.config[keyPath: keyPath] },
            set: { value in self.update(vm.name) { config in config[keyPath: keyPath] = value } }
        )
    }
}
