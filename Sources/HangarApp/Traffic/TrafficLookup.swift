import HangarTraffic

struct TrafficLookup: Identifiable, TrafficRow {
    let id: String
    let event: TrafficEvent

    var isBlocked: Bool { event.verdict == .blocked }
    var searchText: String {
        [event.query ?? "", event.queryType ?? "", (event.answers ?? []).joined(separator: " "), event.reason ?? ""]
            .joined(separator: " ")
    }
}
