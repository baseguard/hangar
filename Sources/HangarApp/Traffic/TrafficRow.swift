import HangarTraffic

protocol TrafficRow {
    var isBlocked: Bool { get }
    var searchText: String { get }
}

extension TrafficConnection: TrafficRow {
    var isBlocked: Bool { verdict == .blocked }
    var searchText: String { [destination, endpoint, proto, reason ?? "", path ?? ""].joined(separator: " ") }
}

extension TrafficHost: TrafficRow {
    var isBlocked: Bool { blocked > 0 }
    var searchText: String { name }
}
