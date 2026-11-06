import HangarKit
import SwiftUI

struct ConnectionChips: View {
    let vm: VMItem

    var body: some View {
        if vm.config.network.mode == .none {
            Chip(systemImage: "network.slash") { Text("No network") }
        } else if let ip = vm.ip, vm.isRunning {
            Chip(systemImage: "network") { CopyableText(ip) }
                .help("IP address")
        } else if vm.isRunning {
            Chip {
                ProgressView().controlSize(.mini)
                Text("Waiting for an address…")
            }
        } else if let reserved = vm.config.network.ipAddress, vm.config.network.mode == .managed {
            Chip(systemImage: "network") { CopyableText(reserved) }
                .help("Reserved address: the VM gets it when it starts")
        }
    }
}
