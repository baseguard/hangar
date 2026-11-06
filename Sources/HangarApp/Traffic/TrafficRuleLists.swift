import HangarKit
import HangarTraffic
import SwiftUI

struct TrafficRuleLists: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    var filter = ""
    @State private var newAllowed = ""
    @State private var newBlocked = ""

    var body: some View {
        RuleListSection(
            vm: vm, title: "Allowed Hosts", keyPath: \.allowed, filter: filter, text: $newAllowed,
            footer:
                "github.com includes its subdomains, *.github.com only the subdomains; networks like 140.82.112.0/20 work too."
        )
        RuleListSection(
            vm: vm, title: "Blocked Hosts", keyPath: \.blocked, filter: filter, text: $newBlocked,
            footer: "Blocked even when an allowed rule also matches.")
        AlsoAllowSection(vm: vm)
    }
}

private struct AlsoAllowSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem

    var body: some View {
        Section("Also Allow") {
            Toggle(isOn: store.trafficBinding(vm, \.allowsHost)) {
                Text("This Mac")
                Text(
                    "Servers running on this Mac, like a local web server. DNS through this Mac, and this Mac connecting to the VM, always work."
                )
            }
            Toggle(isOn: store.trafficBinding(vm, \.allowsVMs)) {
                Text("Other VMs")
                Text("Every VM on Hangar's network. To allow only some, add their addresses to Allowed Hosts.")
            }
            Toggle(isOn: store.trafficBinding(vm, \.allowsLocalNetwork)) {
                Text("Local network")
                Text(
                    "Every private address outside Hangar's network, like 192.168.1.0/24: printers, file servers. To allow only some, add them to Allowed Hosts."
                )
            }
            Toggle(isOn: store.trafficBinding(vm, \.allowsQUIC)) {
                Text("QUIC (HTTP/3)")
                Text("It hides host names, so the rules can't check it. Browsers use HTTPS instead when it's off.")
            }
            Toggle(isOn: store.trafficBinding(vm, \.allowsUDP)) {
                Text("UDP")
                Text("When off, all UDP is blocked but DNS through this Mac, QUIC included.")
            }
        }
    }
}

private struct RuleListSection: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    let title: String
    let keyPath: WritableKeyPath<TrafficPolicy, [String]> & Sendable
    let filter: String
    @Binding var text: String
    let footer: String

    var body: some View {
        Section {
            ForEach(
                vm.config.traffic[keyPath: keyPath].filter {
                    filter.isEmpty || $0.localizedCaseInsensitiveContains(filter)
                }, id: \.self
            ) { rule in
                HStack {
                    Text(rule).monospaced()
                    Spacer()
                    Button {
                        store.updateTraffic(vm.name) { try $0.remove([rule]) }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).minimumHitArea()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(rule)")
                }
            }
            TextField("Add", text: $text, prompt: Text("github.com, *.npmjs.org, 10.0.0.0/8"))
                .onSubmit(add)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack {
                    Spacer()
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func add() {
        let entries = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !entries.isEmpty else { return }
        let added = store.updateTraffic(vm.name) { [keyPath] policy in
            if keyPath == \.allowed { try policy.allow(entries) } else { try policy.block(entries) }
        }
        if added { text = "" }
    }
}
