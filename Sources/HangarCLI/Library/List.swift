import ArgumentParser
import Foundation
import HangarKit
import HangarSupport
import Synchronization

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the VMs with their state, size and IP address.",
        aliases: ["ls"]
    )

    @Flag(help: "Print JSON, for scripts.")
    var json = false

    func run() throws {
        let bundles = VMLibrary.all()
        if json {
            try printJSON(bundles)
        } else if bundles.isEmpty {
            print("No VMs yet. Create one with `hangar create`.")
        } else {
            printSummary(bundles)
        }
    }

    /// One VM in `--json`; `hangar mcp`'s list_vms passes it on as it is. A VM whose config can't be read gives
    /// only its name and the error.
    private struct Listing: Encodable {
        let name: String
        var error: String?
        var os: String?
        var running: Bool?
        var cpuCount: Int?
        var memorySize: UInt64?
        var diskSize: UInt64?
        var network: String?
        var macAddress: String?
        var autoStart: Bool?
        var host: String?
        var pid: Int32?
        var ip: String?
    }

    private func printJSON(_ bundles: [VMBundle]) throws {
        let listings = bundles.map(Self.listing)
        print(String(decoding: try JSON.encoder.encode(listings), as: UTF8.self))
    }

    private static func listing(of bundle: VMBundle) -> Listing {
        let config: VMConfig
        do {
            config = try bundle.loadConfig()
        } catch {
            return Listing(name: bundle.name, error: error.localizedDescription)
        }

        let run = bundle.runInfo
        return Listing(
            name: bundle.name, os: config.os.rawValue, running: run != nil, cpuCount: config.cpuCount,
            memorySize: config.memorySize, diskSize: bundle.diskSize, network: config.network.mode.rawValue,
            macAddress: config.network.macAddress, autoStart: config.autoStart, host: run?.host.rawValue,
            pid: run?.pid, ip: run.flatMap { IPResolver.ipAddress(for: config, startedAt: $0.startedAt) })
    }

    private func printSummary(_ bundles: [VMBundle]) {
        var rows = [["NAME", "OS", "STATE", "CPU", "MEMORY", "DISK", "NETWORK", "IP"]]
        let states = Self.runningStates(of: bundles)

        for bundle in bundles {
            guard let config = try? bundle.loadConfig() else {
                rows.append([bundle.name, "?", "invalid config", "", "", "", "", ""])
                continue
            }

            let run = bundle.runInfo
            let state =
                run.map { "\(states[bundle.name, default: .running].rawValue) (\($0.host.rawValue))" } ?? "stopped"
            rows.append([
                bundle.name, config.os.rawValue, state, "\(config.cpuCount)",
                ByteSize.format(config.memorySize),
                "\(ByteSize.format(bundle.diskSize)) (\(ByteSize.format(bundle.allocatedSize)) used)",
                config.network.mode.rawValue, ipColumn(for: config, run: run),
            ])
        }

        printTable(rows)
    }

    // A busy VM can take the whole second to answer, so the running VMs are asked at the same time.
    private static func runningStates(of bundles: [VMBundle]) -> [String: MachineState] {
        let running = bundles.filter(\.isRunning)
        let states = Mutex<[String: MachineState]>([:])
        DispatchQueue.concurrentPerform(iterations: running.count) { index in
            let bundle = running[index]
            let state = ControlClient.runningState(of: bundle)
            states.withLock { $0[bundle.name] = state }
        }
        return states.withLock { $0 }
    }
}
