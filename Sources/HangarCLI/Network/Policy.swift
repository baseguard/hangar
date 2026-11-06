import ArgumentParser
import Foundation
import HangarKit
import HangarSupport
import HangarTraffic

struct Policy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change a VM's traffic rules.",
        usage: "hangar policy <vm> [<options>]",
        discussion: """
            Examples:
              hangar policy deb
                  Show deb's rules.
              hangar policy deb --mode allowlist --allow github.com --allow '*.npmjs.org'
                  Let deb reach only GitHub and npm.
              hangar policy deb --mode blocklist --block ads.example.com
                  Let deb reach everything except one host.
              hangar policy deb --isolate on
                  Cut deb off at once; only this Mac can still reach it.

            A rule is a host with its subdomains (github.com), only the subdomains (*.github.com), or an address or \
            network (140.82.112.0/20). Rules are kept on this Mac, out of the VM's reach, and apply to a running VM \
            at once.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @OptionGroup(title: "Rules")
    var rules: RuleOptions

    @OptionGroup(title: "Also allow")
    var reach: ReachOptions

    @OptionGroup(title: "Isolation")
    var isolation: IsolationOptions

    struct RuleOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "monitor: record everything, block nothing. allowlist: block all but the allowed hosts. blocklist: allow all but the blocked hosts. off: don't watch.",
                valueName: "monitor|allowlist|blocklist|off"))
        var mode: TrafficPolicy.Mode?

        @Option(
            name: .customLong("allow"),
            help: ArgumentHelp("Add a host or network to the allow list. Repeatable.", valueName: "rule"))
        var allow: [String] = []

        @Option(
            name: .customLong("block"),
            help: ArgumentHelp("Add a host or network to the block list. Repeatable.", valueName: "rule"))
        var block: [String] = []

        @Option(
            name: .customLong("remove"),
            help: ArgumentHelp("Remove a rule from both lists. Repeatable.", valueName: "rule"))
        var remove: [String] = []
    }

    struct ReachOptions: ParsableArguments {
        @Option(help: ArgumentHelp("Services on this Mac. DNS through this Mac always works.", valueName: "on|off"))
        var host: OnOff?

        @Option(help: ArgumentHelp("Other VMs.", valueName: "on|off"))
        var vms: OnOff?

        @Option(
            help: ArgumentHelp(
                "Private addresses, such as your local network. An allowed network opens just its part.",
                valueName: "on|off"))
        var localNetwork: OnOff?

        @Option(help: ArgumentHelp("QUIC (HTTP/3), which hides host names.", valueName: "on|off"))
        var quic: OnOff?

        @Option(help: ArgumentHelp("UDP. When off, only DNS through this Mac gets through.", valueName: "on|off"))
        var udp: OnOff?
    }

    struct IsolationOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "Cut the VM off at once: it reaches nothing, and only this Mac can reach it.", valueName: "on|off"))
        var isolate: OnOff?
    }

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        guard changes else {
            printPolicy(try bundle.loadConfig())
            return
        }

        let config = try bundle.updateConfig { config in
            config.traffic = try changed(config.traffic)
            try config.traffic.checkRunnable(on: config.network.mode)
        }
        printPolicy(config)
        guard bundle.isRunning else { return }

        do {
            _ = try ControlClient.send(.reloadTrafficRules, to: bundle)
        } catch {
            throw HangarError("Saved, but could not apply it to the running VM: \(error.localizedDescription)")
        }

        print("\nApplied to the running VM.")
    }

    private var changes: Bool {
        rules.mode != nil || !rules.allow.isEmpty || !rules.block.isEmpty || !rules.remove.isEmpty
            || reach.host != nil || reach.vms != nil || reach.localNetwork != nil || reach.quic != nil
            || reach.udp != nil || isolation.isolate != nil
    }

    private func changed(_ original: TrafficPolicy) throws -> TrafficPolicy {
        var policy = original
        if let mode = rules.mode { policy.mode = mode }
        try policy.remove(rules.remove)
        try policy.allow(rules.allow)
        try policy.block(rules.block)
        if let host = reach.host { policy.allowsHost = host == .on }
        if let vms = reach.vms { policy.allowsVMs = vms == .on }
        if let localNetwork = reach.localNetwork { policy.allowsLocalNetwork = localNetwork == .on }
        if let quic = reach.quic { policy.allowsQUIC = quic == .on }
        if let udp = reach.udp { policy.allowsUDP = udp == .on }
        if let isolate = isolation.isolate { policy.isolated = isolate == .on }
        return policy
    }

    private func printPolicy(_ config: VMConfig) {
        let policy = config.traffic
        let modes: [TrafficPolicy.Mode: String] = [
            .off: "off (not watched)",
            .monitor: "monitor (records everything, blocks nothing)",
            .allowlist: "allowlist (blocks everything except the allowed hosts)",
            .blocklist: "blocklist (allows everything except the blocked hosts)",
        ]
        var rows: [(String, String)] = [
            ("Mode", modes[policy.mode] ?? policy.mode.rawValue),
            ("Isolated", policy.isolated ? "YES, only this Mac can reach the VM" : "no"),
            ("Allowed", policy.allowed.isEmpty ? "–" : policy.allowed.joined(separator: ", ")),
            ("Blocked", policy.blocked.isEmpty ? "–" : policy.blocked.joined(separator: ", ")),
            ("This Mac", policy.allowsHost ? "allowed" : "blocked, except DNS"),
            ("Other VMs", policy.allowsVMs ? "allowed" : "blocked"),
            ("Local network", policy.allowsLocalNetwork ? "allowed" : "blocked, except allowed networks"),
            ("QUIC", policy.allowsQUIC ? "allowed" : "blocked"),
            ("UDP", policy.allowsUDP ? "allowed" : "blocked, except DNS through this Mac"),
        ]

        if policy.watches, !policy.enforces {
            rows.append(("Note", "monitor mode blocks nothing; the rules above apply in allowlist and blocklist modes"))
        }

        if config.network.mode != .managed {
            rows.append(("Note", "the VM is not on the Hangar Managed network, so its traffic is not watched"))
        }

        printFields(rows)
    }
}
