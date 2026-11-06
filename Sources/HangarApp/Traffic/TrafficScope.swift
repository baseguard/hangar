extension TrafficPage {
    enum Scope: String, CaseIterable {
        case connections = "Connections"
        case hosts = "Hosts"
        case lookups = "DNS"
        case rules = "Rules"

        var hasDetails: Bool { self == .connections || self == .lookups }
    }
}
