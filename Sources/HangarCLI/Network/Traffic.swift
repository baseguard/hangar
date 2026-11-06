import ArgumentParser
import Foundation
import HangarKit
import HangarSupport
import HangarTraffic

struct Traffic: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show where a VM's network traffic goes.",
        discussion: """
            Examples:
              hangar traffic deb
                  The last 50 connections and DNS lookups.
              hangar traffic deb --follow
                  Keep printing new traffic as it happens.
              hangar traffic deb --summary
                  Totals per host.
              hangar traffic deb --blocked
                  Only what the traffic rules blocked.

            Hangar watches Hangar Managed VMs from this Mac, outside the VM. For HTTPS it sees the host name, not \
            the page. Change the rules with `hangar policy`.
            """
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
    var name: String

    @OptionGroup var log: LogOptions

    @Flag(help: "Show only what was blocked.")
    var blocked = false

    @Flag(help: "Hide DNS lookups.")
    var noDns = false

    @Flag(help: "Show totals per host instead of each connection.")
    var summary = false

    @Flag(help: "Print each event as a line of JSON, for scripts.")
    var json = false

    /// A summary or a blocked-only view reads far back; a plain listing reads a few events per shown line.
    private static let summaryEventLimit = 200_000
    private static let eventsPerLine = 8

    func validate() throws {
        if summary, log.follow || json { throw ValidationError("--summary can't be combined with --follow or --json.") }
    }

    func run() throws {
        let bundle = try VMLibrary.bundle(named: name)
        let config = try bundle.loadConfig()
        let limit = summary || blocked ? Self.summaryEventLimit : log.count * Self.eventsPerLine
        let events = TrafficLog.recent(in: bundle.trafficLogURL, limit: limit)

        if events.isEmpty, !log.follow {
            print(emptyHint(config))
            return
        }

        if summary {
            printSummary(TrafficReport.hosts(from: events))
            return
        }

        if json {
            for event in events.filter(shows).suffix(log.count) {
                printJSON(event)
            }
        } else {
            for line in lines(for: events).suffix(log.count) {
                print(line)
            }
        }

        guard log.follow else { return }

        let follower = TrafficLog.Follower(url: bundle.trafficLogURL)

        while true {
            for event in follower.next() where shows(event) {
                if json { printJSON(event) } else if let line = line(for: event) { print(line) }
            }
            fflush(stdout)
            Thread.sleep(forTimeInterval: LogOptions.followInterval)
        }
    }

    private func shows(_ event: TrafficEvent) -> Bool {
        if blocked { return event.verdict == .blocked && event.kind != .close }
        return !(noDns && event.kind == .dns)
    }

    private func lines(for events: [TrafficEvent]) -> [String] {
        var rows: [(Date, String)] = TrafficReport.connections(from: events)
            .filter { !blocked || $0.verdict == .blocked }
            .map { ($0.time, TrafficFormat.line($0)) }
        for event in events where [.dns, .start, .policy, .notice].contains(event.kind) && shows(event) {
            if let line = line(for: event) { rows.append((event.time, line)) }
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func line(for event: TrafficEvent) -> String? {
        switch event.kind {
        case .start: TrafficFormat.notice(event, "started watching (\(event.mode ?? "?"))")
        case .policy: TrafficFormat.notice(event, "rules changed (\(event.mode ?? "?"))")
        case .notice: TrafficFormat.notice(event, event.reason ?? "")
        case .dns: TrafficFormat.dns(event)
        case .connect, .request, .block, .close: TrafficFormat.event(event)
        }
    }

    private func printJSON(_ event: TrafficEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            print(String(decoding: try encoder.encode(event), as: UTF8.self))
        } catch {
            printError("Could not write a traffic event as JSON: \(error)")
        }
    }

    private func printSummary(_ hosts: [TrafficHost]) {
        var rows = [["HOST", "CONNECTIONS", "LOOKUPS", "BLOCKED", "SENT", "RECEIVED", "LAST SEEN"]]
        for host in hosts where !blocked || host.blocked > 0 {
            rows.append([
                host.name, "\(host.connections)", "\(host.lookups)", "\(host.blocked)",
                ByteSize.format(host.sent), ByteSize.format(host.received), TrafficFormat.time(host.lastSeen),
            ])
        }
        printTable(rows)
    }

    private func emptyHint(_ config: VMConfig) -> String {
        if config.network.mode != .managed {
            return
                "'\(name)' is not on the Hangar Managed network, so Hangar can't see its traffic (hangar set \(name) --network managed)."
        }
        if !config.traffic.watches {
            return "Traffic watching is off for '\(name)'. Turn it on with `hangar policy \(name) --mode monitor`."
        }
        return "No traffic recorded for '\(name)' yet."
    }
}
