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
    private(set) var travelRecoveryMessages: [UUID: String] = [:]
    @ObservationIgnored private var resultIdentities = SearchResultIdentityRegistry()
    @ObservationIgnored private var travelRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var travelRecoveries: [UUID: TravelRecovery] = [:]
    @ObservationIgnored private var estimateRanking: (intent: ClassifiedQuery, context: SearchContext)?
    private var placeSearchTask: Task<Void, Never>?
    private var transitSearchTask: Task<Void, Never>?

    private enum TravelRecovery {
        case pending
        case resolved(RoutedTravelMetrics)
        case failed
    }

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

    func configureEstimateRanking(query: String, context: SearchContext) {
        var intent = QueryClassifier().classify(query)
        intent.alongRoute = intent.alongRoute || alongRoute
        estimateRanking = (intent, context)
    }

    func publishResults(_ results: [SearchResult]) {
        self.results = resultIdentities.stabilize(results).map { result in
            guard let recovery = travelRecoveries[result.id] else { return result }
            // A later matrix reply is authoritative when it supplies both metrics.
            // Remember it so a still later metadata-only reply cannot erase it.
            if let metrics = RoutedTravelMetrics(time: result.travelTime, distance: result.travelDistance) {
                travelRecoveries[result.id] = .resolved(metrics)
                travelRecoveryMessages[result.id] = nil
                return result
            }
            var updated = result
            switch recovery {
            case .pending:
                updated.travelEstimateStatus = .calculating
            case .resolved(let metrics):
                updated.travelTime = metrics.time
                updated.travelDistance = metrics.distance
                updated.travelEstimateStatus = .notRequested
            case .failed:
                updated.travelEstimateStatus = .unavailable
            }
            return updated
        }
        rankResultsWithTravelEstimates()
        isShowingPreviousResults = false
    }

    func retryTravelEstimate(
        for result: SearchResult,
        estimator: @escaping @MainActor (Destination) async throws -> SearchRouteEstimate?,
        onUpdate: @escaping @MainActor ([SearchResult]) -> Void
    ) {
        guard !isShowingPreviousResults,
              travelRecoveryTasks[result.id] == nil,
              let index = results.firstIndex(where: { $0.id == result.id }),
              results[index].needsTravelEstimate
        else { return }
        let id = result.id
        let requestID = currentRequestID
        let destination = results[index].navigationDestination
        travelRecoveries[id] = .pending
        travelRecoveryMessages[id] = nil
        results[index].travelEstimateStatus = .calculating
        travelRecoveryTasks[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let recovered: RoutedTravelMetrics?
            do {
                let estimate = try await estimator(destination)
                recovered = RoutedTravelMetrics(time: estimate?.travelTime, distance: estimate?.distanceMeters)
            } catch {
                recovered = nil
            }
            guard let self, !Task.isCancelled, self.isCurrentRequest(requestID) else { return }
            self.travelRecoveryTasks[id] = nil
            guard let currentIndex = self.results.firstIndex(where: { $0.id == id }) else {
                // A place can briefly leave the visible top results as sources arrive.
                // Retain this request's recovery for its next metadata update.
                if let existing = self.travelRecoveries[id], case .resolved = existing { return }
                if let recovered {
                    self.travelRecoveries[id] = .resolved(recovered)
                    self.travelRecoveryMessages[id] = nil
                } else {
                    self.travelRecoveries[id] = .failed
                    self.travelRecoveryMessages[id] = "Spróbuj ponownie lub wybierz miejsce, aby zaplanować trasę."
                }
                return
            }
            // The matrix may have completed while this individual route was pending.
            let currentMetrics = RoutedTravelMetrics(time: self.results[currentIndex].travelTime,
                                                     distance: self.results[currentIndex].travelDistance)
            if let metrics = currentMetrics ?? recovered {
                self.travelRecoveries[id] = .resolved(metrics)
                self.results[currentIndex].travelTime = metrics.time
                self.results[currentIndex].travelDistance = metrics.distance
                self.results[currentIndex].travelEstimateStatus = .notRequested
                self.travelRecoveryMessages[id] = nil
            } else {
                self.travelRecoveries[id] = .failed
                self.results[currentIndex].travelTime = self.results[currentIndex].travelTime.flatMap {
                    $0.isFinite && (0...31_536_000).contains($0) ? $0 : nil
                }
                self.results[currentIndex].travelDistance = self.results[currentIndex].travelDistance.flatMap {
                    $0.isFinite && (0...400_000_000).contains($0) ? $0 : nil
                }
                self.results[currentIndex].travelEstimateStatus = .unavailable
                self.travelRecoveryMessages[id] = "Spróbuj ponownie lub wybierz miejsce, aby zaplanować trasę."
            }
            self.rankResultsWithTravelEstimates()
            onUpdate(self.results)
        }
        rankResultsWithTravelEstimates()
        onUpdate(results)
    }

    private func rankResultsWithTravelEstimates() {
        guard let estimateRanking else { return }
        results.sort {
            SearchRanking.precedes($0, $1, intent: estimateRanking.intent,
                                   context: estimateRanking.context, withTravelEstimates: true)
        }
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
        cancelTravelRecoveries()
        for index in results.indices where results[index].travelEstimateStatus == .calculating {
            results[index].travelEstimateStatus = results[index].needsTravelEstimate ? .unavailable : .notRequested
        }
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
        estimateRanking = nil
    }

    private func cancelTravelRecoveries() {
        for task in travelRecoveryTasks.values { task.cancel() }
        travelRecoveryTasks = [:]
        travelRecoveries = [:]
        travelRecoveryMessages = [:]
    }

    func searchContext(navigation state: NavigationState, places: [SavedPlace],
                       recentSearches: [SearchHistoryEntry]) async -> SearchContext {
        let currentLocation = SearchLocationContext.coordinate(in: state)
        var remainingRoute: [Coordinate] = []
        if state.status == .navigating || state.status == .rerouting,
           let route = state.route, let origin = currentLocation,
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
        return SearchContext(origin: currentLocation,
                             area: searchArea ?? currentLocation,
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
