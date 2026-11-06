import HangarKit
import SwiftUI

struct HeroActions: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        switch vm.phase {
        case .stopped, .failed:
            HStack {
                HeroStartButton(vm: vm)
                if store.startingNetwork.contains(vm.name) {
                    ProgressView().controlSize(.small)
                    Text("Starting the network…")
                        .foregroundStyle(.secondary)
                }
            }
        case .busy:
            ProgressView()
                .controlSize(.small)
        case .running:
            ConnectButton(vm: vm)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        case .paused:
            EmptyView()
        }
    }
}

struct ConnectButton: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        if vm.config.os == .windows {
            Button {
                store.openRemoteDesktop(vm.name)
            } label: {
                Label("Remote Desktop", systemImage: "display")
            }
            .disabled(vm.ip == nil || !vm.config.remoteDesktop)
            .help(
                vm.config.remoteDesktop
                    ? "Open in Remote Desktop, at any resolution"
                    : "Remote Desktop was turned off when this VM was created")
        } else {
            Button {
                store.openSSH(vm.name)
            } label: {
                Label("SSH", systemImage: "terminal")
            }
            .disabled(vm.ip == nil)
            .help("Open an SSH session in Terminal")
        }
    }
}
