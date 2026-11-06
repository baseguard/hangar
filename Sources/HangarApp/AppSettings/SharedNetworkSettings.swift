import HangarKit
import HangarPackets
import HangarSupport
import SwiftUI

struct SharedNetworkSettings: View {
    @Environment(VMStore.self) private var store
    @State private var subnet = SharedNetwork.subnet.description
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("Subnet", text: $subnet, prompt: Text("192.168.73.1/24"))
                    .onSubmit(apply)
                LabeledContent {
                    Button("Apply", action: apply)
                        .disabled(subnet == store.subnet.description || managedVMIsRunning)
                } label: {
                    if managedVMIsRunning {
                        Notice(text: "Shut down the Hangar Managed VMs first.", systemImage: "lock.fill")
                    }
                }
            } header: {
                Text("Hangar's Network")
            } footer: {
                Text(
                    "This Mac's address on the VM network, with its prefix (/16 to /29). Pick a range your other networks don't use."
                )
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var managedVMIsRunning: Bool {
        store.vms.contains { $0.config.network.mode == .managed && $0.isRunning }
    }

    private func apply() {
        guard let parsed = IPv4Subnet(subnet.trimmingCharacters(in: .whitespaces)) else {
            message = "Use the host address and a prefix between /16 and /29, e.g. 192.168.73.1/24."
            return
        }

        Task {
            do {
                let skipped = try await runInBackground { try SharedNetwork.changeSubnet(to: parsed) }
                message =
                    skipped.isEmpty
                    ? "Subnet set to \(parsed)."
                    : "Subnet set to \(parsed). Couldn't update \(skipped.joined(separator: ", ")), so they keep their old addresses."
                store.refresh()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
