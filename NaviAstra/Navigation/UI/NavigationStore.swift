import Foundation
import Observation

@MainActor
@Observable
final class NavigationStore {
    @ObservationIgnored private let session: NavigationSession

    var state: NavigationState { session.state }
    var energyPolicy: EnergyPolicy { session.energyPolicyEngine.currentPolicy }

    var onTripFinished: ((TripRecord) -> Void)? {
        get { session.onTripFinished }
        set { session.onTripFinished = newValue }
    }

    init(session: NavigationSession) {
        self.session = session
    }

    func startLocation() { session.startLocation() }
    func setAppIsForeground(_ isForeground: Bool) { session.setAppIsForeground(isForeground) }
    func refreshEnergyPolicy() { session.refreshEnergyPolicy() }

    func updateRoutingEndpoint(_ endpoint: URL) {
        let dependencies = NavigationRoutingDependencies.live(
            routeEndpoint: endpoint,
            transitProvider: session.transitProvider)
        session.updateRoutingDependencies(dependencies)
    }

    func updateRoutingPreferences(_ preferences: RoutingPreferences) async {
        await session.updateRoutingPreferences(preferences)
    }

    func selectTransportMode(_ mode: TransportMode) async {
        await session.selectTransportMode(mode)
    }

    func setJourneyTimeMode(_ mode: JourneyTimeMode) { session.setJourneyTimeMode(mode) }
    func setJourneyTargetTime(_ date: Date) { session.setJourneyTargetTime(date) }

    func loadLaterTransitConnections(after departure: Date) async {
        await session.loadLaterTransitConnections(after: departure)
    }

    func selectLaterTransitConnection(_ route: NavigationRoute) {
        session.selectLaterTransitConnection(route)
    }

    func updateTransitTripDetails(_ details: TransitTripDetails?, tripID: String?) {
        session.updateTransitTripDetails(details, tripID: tripID)
    }

    func refreshTransitRouteIfNeeded() async { await session.refreshTransitRouteIfNeeded() }

    func estimatedWalkingRoute(to destination: Destination) async throws -> SearchRouteEstimate? {
        try await session.estimatedWalkingRoute(to: destination)
    }

    func estimatedCarRouteEstimate(to destination: Destination) async -> PlaceRouteEstimate? {
        await session.estimatedCarRouteEstimate(to: destination)
    }

    func estimatedCarRouteEstimate(to destination: Destination,
                                   from origin: Coordinate) async -> PlaceRouteEstimate? {
        await session.estimatedCarRouteEstimate(to: destination, from: origin)
    }

    func estimatedSearchRoute(from origin: Coordinate, to destination: Destination,
                              mode: TransportMode) async throws -> SearchRouteEstimate? {
        try await session.estimatedSearchRoute(from: origin, to: destination, mode: mode)
    }

    func selectDestination(_ destination: Destination, applyConfiguredMode: Bool = true) {
        session.selectDestination(destination, applyConfiguredMode: applyConfiguredMode)
    }

    func setRouteOrigin(_ point: RoutePoint?) async { await session.setRouteOrigin(point) }
    func swapRoutePoints() async { await session.swapRoutePoints() }
    func planRoute() async { await session.planRoute() }
    func addWaypoint(_ destination: Destination) async { await session.addWaypoint(destination) }
    func removeWaypoint(_ id: UUID) async { await session.removeWaypoint(id) }
    func moveWaypoint(_ id: UUID, by offset: Int) async { await session.moveWaypoint(id, by: offset) }
    func reorderWaypoint(_ id: UUID, to index: Int) async { await session.reorderWaypoint(id, to: index) }
    func reorderRouteStop(_ id: String, to index: Int) async { await session.reorderRouteStop(id, to: index) }
    func optimizeWaypoints() async { await session.optimizeWaypoints() }

    func searchNearbyPlaces(_ category: NearbyPlaceCategory, nearDestination: Bool = false,
                            searchRadius: Double = 5_000, resultLimit: Int = 25) async {
        await session.searchNearbyPlaces(category, nearDestination: nearDestination,
                                         searchRadius: searchRadius, resultLimit: resultLimit)
    }

    func estimateNearbyTravel(for candidateID: String) async {
        await session.estimateNearbyTravel(for: candidateID)
    }

    func selectNearbyPlace(_ destination: Destination, asFinalParking: Bool) async {
        await session.selectNearbyPlace(destination, asFinalParking: asFinalParking)
    }

    func previewNewTrip(_ destination: Destination) async { await session.previewNewTrip(destination) }
    func select(_ route: NavigationRoute) { session.select(route) }
    func setVoiceEnabled(_ enabled: Bool) { session.setVoiceEnabled(enabled) }
    func setVoicePreferences(_ preferences: VoiceGuidancePreferences) {
        session.setVoicePreferences(preferences)
    }

    func begin() { session.begin() }
    func stop() { session.stop() }
    func refreshTraffic(force: Bool = false, forceRouteRefresh: Bool = true) {
        session.refreshTraffic(force: force, forceRouteRefresh: forceRouteRefresh)
    }

    func showRouteOverview() { session.showRouteOverview() }
    func refreshCurrentLocation() { session.refreshCurrentLocation() }
    func returnToFollow() { session.returnToFollow() }
    func focusMap(on coordinate: Coordinate, zoom: Double = 15.5) {
        session.focusMap(on: coordinate, zoom: zoom)
    }
}
