import SwiftUI

struct USBDeviceItems: View {
    @Environment(VMStore.self) private var store
    let name: String
    private let devices = USBDevices.shared

    var body: some View {
        if let reason = devices.unavailableReason {
            Text(reason)
        } else if devices.devices.isEmpty {
            Text("No USB devices connected")
        }
        ForEach(devices.devices) { device in
            let owner = devices.owner(of: device)
            Button {
                if owner == name {
                    store.detachUSB(device)
                } else {
                    store.attachUSB(device, to: name)
                }
            } label: {
                if owner == name {
                    Label(device.name, systemImage: "checkmark")
                } else {
                    Text(owner.map { "\(device.name) (in \($0))" } ?? device.name)
                }
            }
            .disabled(owner != nil && owner != name)
        }
    }
}
