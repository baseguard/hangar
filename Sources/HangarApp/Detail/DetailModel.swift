import HangarTraffic
import Observation

@Observable
final class DetailModel {
    var page: VMDetailView.Page {
        didSet { if !visited.contains(page) { visited.insert(page) } }
    }

    private(set) var visited: Set<VMDetailView.Page>
    var activity = TrafficActivity()
    var trafficScope = TrafficPage.Scope.connections
    var showsTrafficDetails = false
    var connectionSelection = Set<TrafficConnection.ID>()
    var lookupSelection = Set<TrafficLookup.ID>()

    var trafficDetailsShown: Bool { showsTrafficDetails && page == .traffic && trafficScope.hasDetails }

    init(page: VMDetailView.Page = .overview) {
        self.page = page
        visited = [page]
    }
}
