import Foundation
import Observation

enum DestinationSearchScope: String, CaseIterable, Identifiable {
    case places = "Miejsca"
    case transit = "Transport publiczny"

    var id: String { rawValue }
}

@MainActor
@Observable
final class SearchStore {
    private let transitRepository: TransitDataProviding

    var query = ""
    var scope: DestinationSearchScope = .places
    var results: [SearchResult] = []
    var transitResults = TransitSearchResults(stops: [], lines: [])
    var isTransitSearching = false
    var searchError: SearchError?
    var didCompleteSearchWithNoResults = false
    var isSearching = false
    var searchArea: Coordinate?
    var alongRoute = false

    private(set) var isShowingPreviousResults = false
    private(set) var currentRequestID = UUID()
    @ObservationIgnored private var resultIdentities = SearchResultIdentityRegistry()
    private var placeSearchTask: Task<Void, Never>?
    private var transitSearchTask: Task<Void, Never>?

    init(transitRepository: TransitDataProviding) {
        self.transitRepository = transitRepository
    }

    func resetForPresentation(selectingRouteOrigin: Bool) {
        cancelSearches()
        query = ""
        if selectingRouteOrigin {
            scope = .places
            alongRoute = false
        }
        results = []
        transitResults = TransitSearchResults(stops: [], lines: [])
        searchError = nil
        didCompleteSearchWithNoResults = false
        isSearching = false
        isTransitSearching = false
        isShowingPreviousResults = false
        resultIdentities = SearchResultIdentityRegistry()
        currentRequestID = UUID()
    }

    func beginRequest(preservingResults: Bool = false) -> UUID {
        cancelSearches()
        currentRequestID = UUID()
        searchError = nil
        didCompleteSearchWithNoResults = false
        isSearching = false
        isTransitSearching = false
        isShowingPreviousResults = preservingResults
            && (!results.isEmpty || !transitResults.stops.isEmpty || !transitResults.lines.isEmpty)
        if !preservingResults {
            results = []
            transitResults = TransitSearchResults(stops: [], lines: [])
            resultIdentities = SearchResultIdentityRegistry()
        }
        return currentRequestID
    }

    func publishResults(_ results: [SearchResult]) {
        self.results = resultIdentities.stabilize(results)
        isShowingPreviousResults = false
    }

    func publishTransitResults(_ results: TransitSearchResults) {
        transitResults = results
        isShowingPreviousResults = false
    }

    func discardPreviousResults() {
        guard isShowingPreviousResults else { return }
        results = []
        transitResults = TransitSearchResults(stops: [], lines: [])
        isShowingPreviousResults = false
        resultIdentities = SearchResultIdentityRegistry()
    }

    func isCurrentRequest(_ id: UUID) -> Bool {
        currentRequestID == id
    }

    func setPlaceSearchTask(_ task: Task<Void, Never>) {
        placeSearchTask = task
    }

    func setTransitSearchTask(_ task: Task<Void, Never>) {
        transitSearchTask = task
    }

    func cancelPlaceSearch() {
        placeSearchTask?.cancel()
        placeSearchTask = nil
    }

    func cancelTransitSearch() {
        transitSearchTask?.cancel()
        transitSearchTask = nil
    }

    func cancelSearches() {
        // A provider may finish after cancellation. Invalidate its callbacks even
        // when the next action closes the sheet instead of starting another query.
        currentRequestID = UUID()
        cancelPlaceSearch()
        cancelTransitSearch()
        isSearching = false
        isTransitSearching = false
    }

    func searchContext(navigation state: NavigationState, places: [SavedPlace],
                       recentSearches: [SearchHistoryEntry]) async -> SearchContext {
        var remainingRoute: [Coordinate] = []
        if state.status == .navigating || state.status == .rerouting,
           let route = state.route, let origin = state.location?.coordinate,
           let projection = MapMatcher.project(origin, onto: route.coordinates) {
            remainingRoute = [projection.coordinate] + Array(route.coordinates.dropFirst(projection.segment + 1))
        }
        let routeTarget: Coordinate?
        if let waypoint = state.waypoints.first {
            if alongRoute, waypoint.poi != nil {
                routeTarget = await POIAccessResolver.shared.resolve(for: waypoint,
                                                                      mode: state.transportMode)?.coordinate
                    ?? waypoint.coordinate
            } else {
                routeTarget = waypoint.coordinate
            }
        } else if state.destination?.poi != nil {
            routeTarget = state.navigationTarget?.coordinate ?? state.destination?.coordinate
        } else {
            routeTarget = state.destination?.coordinate
        }
        return SearchContext(origin: state.location?.coordinate ?? searchArea ?? state.searchMapCenter,
                             area: searchArea,
                             route: remainingRoute, routeTarget: routeTarget,
                             mode: state.transportMode, preferences: state.routingPreferences,
                             localDestinations: places.map(\.navigationDestination)
                                + recentSearches.map(\.destination))
    }

    func searchPlaces(_ rawQuery: String, context: SearchContext, includeUUGFallback: Bool,
                      routingServerAddress: String,
                      routeEstimator: SearchRouteEstimator = { _, _, _ in nil },
                      onUpdate: @escaping @MainActor ([SearchResult]) -> Void) async throws -> [SearchResult] {
        let endpoint = URL(string: routingServerAddress) ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let normalizedQuery = QueryClassifier.normalize(rawQuery)
        let effectiveQuery = alongRoute && !normalizedQuery.hasSuffix(" po trasie")
            ? rawQuery + " po trasie" : rawQuery
        return try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint))
            .search(effectiveQuery, context: context, includeUUGFallback: includeUUGFallback,
                    routeEstimator: routeEstimator, onUpdate: onUpdate)
    }

    func searchTransit(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults {
        await transitRepository.search(query, near: coordinate)
    }
}
