import HangarKit
import HangarPackets
import SwiftUI

struct NetworkView: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        Form {
            SharedNetworkSection()
            ManagedVMsSection()
            NATVMsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Network")
        .navigationSubtitle(store.network != nil ? "Running" : "Stopped")
    }
}

private struct SharedNetworkSection: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        let subnet = store.network?.subnet ?? store.subnet
        Section {
            LabeledContent("Status") {
                HStack {
                    StatusPill(phase: store.network != nil ? .running : .stopped)
                    if let network = store.network {
                        Text("since \(network.startedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Subnet") { CopyableText(subnet.description) }
            LabeledContent("This Mac") { CopyableText(subnet.gateway.description) }
            LabeledContent("DHCP server") { Text(subnet.serverAddress.description).monospaced() }
            HStack {
                Spacer()
                SettingsLink { Text("Change Subnet…") }
            }
        } header: {
            Text("Hangar's Network")
        } footer: {
            Text(
                "Hangar Managed VMs use it: internet access and DNS through this Mac, traffic rules, and VMs reach each other. This Mac reaches them, and nothing is bridged to your LAN. It starts with the first Hangar Managed VM and stops \(NetworkDaemon.idleMinutes) minutes after the last one."
            )
        }
    }
}

private struct ManagedVMsSection: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        Section("Hangar Managed") {
            let managed = store.vms.filter { $0.config.network.mode == .managed }
            if managed.isEmpty {
                Text("No Hangar Managed VMs.").foregroundStyle(.secondary)
            }
            ForEach(managed) { vm in
                HStack {
                    OSBadge(os: vm.config.os, size: Metrics.regularControlSize)
                    Text(vm.name)
                    PhaseIndicator(phase: vm.phase)
                    Spacer()
                    Text(vm.config.network.macAddress)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                    Text(vm.ip ?? vm.config.network.ipAddress ?? "–")
                        .monospaced()
                }
            }
        }
    }
}

private struct NATVMsSection: View {
    @Environment(VMStore.self) private var store

    var body: some View {
        let natVMs = store.vms.filter { $0.config.network.mode == .nat }
        if !natVMs.isEmpty {
            Section {
                ForEach(natVMs) { vm in
                    HStack {
                        OSBadge(os: vm.config.os, size: Metrics.regularControlSize)
                        Text(vm.name)
                        Spacer()
                        Text(vm.ip ?? "–").monospaced()
                    }
                }
            } header: {
                Text("NAT")
            } footer: {
                Text(
                    "These VMs use the system's NAT: they reach the internet and this Mac but not each other, and they have no traffic rules. Switch them to Hangar Managed in Settings."
                )
            }
        }
    }
}
