import ArgumentParser
import Foundation
import HangarKit
import HangarPackets
import HangarSupport

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Show or change Hangar's network, the one Hangar Managed VMs use.",
        discussion: """
            Examples:
              hangar network
                  Whether it runs, its subnet and the VMs on it.
              hangar network set --subnet 10.80.0.1/24
                  Move it to another range, e.g. when it clashes with your LAN or VPN.
              hangar network logs --follow
                  Watch what it writes to its log.

            It starts with the first Hangar Managed VM and stops \(NetworkDaemon.idleMinutes) minutes after the last one.
            """,
        subcommands: [Status.self, StopDaemon.self, SetSubnet.self, Logs.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether Hangar's network runs, its subnet and the VMs on it.")

        func run() throws {
            if SharedNetwork.state == nil, let pid = SharedNetwork.daemonHoldingLock {
                print("Hangar's network: starting (pid \(pid)). Subnet \(SharedNetwork.subnet).")
                return
            }
            guard let state = SharedNetwork.state else {
                print(
                    "Hangar's network: not running (starts with the first Hangar Managed VM). Subnet \(SharedNetwork.subnet)."
                )
                return
            }

            let uptime = Int(Date().timeIntervalSince(state.startedAt))
            print("Hangar's network: running (pid \(state.pid), up \(uptime / 60)m \(uptime % 60)s)")
            print("Subnet:  \(state.subnet)  (host is \(state.subnet.gateway))")
            var rows = [["VM", "STATE", "MAC", "IP"]]

            for bundle in VMLibrary.all() {
                guard let config = try? bundle.loadConfig(), config.network.mode == .managed else { continue }
                let run = bundle.runInfo
                let state = run != nil ? "running" : "stopped"
                rows.append([bundle.name, state, config.network.macAddress, ipColumn(for: config, run: run)])
            }

            if rows.count > 1 {
                print("")
                printTable(rows)
            }
        }
    }

    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the log of Hangar's network.")

        @OptionGroup var options: LogOptions

        func run() throws {
            options.show(
                SharedNetwork.logURL,
                emptyHint: "Hangar's network has no log yet. It starts with the first Hangar Managed VM.")
        }
    }

    struct StopDaemon: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop Hangar's network now. Running Hangar Managed VMs lose their connection.")

        func run() throws {
            guard SharedNetwork.isDaemonRunning else {
                print("Hangar's network is not running.")
                return
            }
            guard SharedNetwork.stopDaemon() else {
                throw HangarError("The network daemon did not stop. See \(SharedNetwork.logURL.path).")
            }
            print("Stopped Hangar's network.")
        }
    }

    struct SetSubnet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Move Hangar's network to another subnet. Shut the Hangar Managed VMs down first."
        )

        @Option(
            help: ArgumentHelp(
                "This Mac's address on the network with its prefix, /16 to /29, e.g. 10.80.0.1/24.",
                valueName: "address/prefix"))
        var subnet: String

        func validate() throws {
            _ = try requestedSubnet()
        }

        func run() throws {
            let newSubnet = try requestedSubnet()
            let skipped = try SharedNetwork.changeSubnet(to: newSubnet)
            print("Hangar's network now uses \(newSubnet).")
            for name in skipped {
                printError(
                    "warning: could not update the config of '\(name)', so it keeps its old address. Check `hangar info \(name)`."
                )
            }
        }

        private func requestedSubnet() throws -> IPv4Subnet {
            guard let newSubnet = IPv4Subnet(subnet) else {
                throw ValidationError("Use the host address with a prefix between /16 and /29, e.g. 192.168.73.1/24.")
            }
            return newSubnet
        }
    }
}
