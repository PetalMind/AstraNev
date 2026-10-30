#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct VoiceEditingCriticalTests {
    @Test
    func nextStopUsesProgressAfterPriorityIDsHaveBeenCleared() async throws {
        let session = makeSession()
        let first = try #require(session.state.waypoints.first)
        let second = try #require(session.state.waypoints.last)
        #expect(session.state.pendingWaypointIDs.isEmpty)
        #expect(session.nextVoiceWaypoint?.id == first.id)
        advance(session, alongRoute: 800, latitude: 52.0072)
        #expect(session.nextVoiceWaypoint?.id == second.id)
        let before = session.state.waypoints
        await session.removeVoiceWaypoint(first.id)
        #expect(session.state.waypoints == before)
        #expect(session.state.errorMessage?.contains("Kolejny postój się zmienił") == true)
    }

    @Test
    func failedStopRemovalRestoresManualAndEVPlan() async throws {
        let session = makeSession()
        let first = try #require(session.nextVoiceWaypoint)
        let routeID = session.state.route?.id
        let stops = session.state.waypoints
        let evStops = session.state.evChargingStops
        let targets = session.state.waypointNavigationTargets
        await session.removeVoiceWaypoint(first.id)
        #expect(session.state.route?.id == routeID)
        #expect(session.state.status == .navigating)
        #expect(session.state.waypoints == stops)
        #expect(session.state.evChargingStops == evStops)
        #expect(session.state.waypointNavigationTargets == targets)
        #expect(session.tripSession?.waypoints == stops)
        #expect(session.state.errorMessage?.contains("Przywrócono") == true)
    }

    @Test
    func failedDestinationAndPreferencesDoNotLeaveOldGeometryWithNewPlan() async throws {
        let session = makeSession()
        let oldDestination = session.state.destination
        let oldRouteID = session.state.route?.id
        let oldPreferences = session.state.routingPreferences
        let oldEVStops = session.state.evChargingStops
        await session.replaceVoiceDestination(Destination(name: "Inny cel", coordinate: .init(latitude: 52.03, longitude: 21)))
        #expect(session.state.destination == oldDestination)
        #expect(session.tripSession?.destination == oldDestination)
        #expect(session.state.route?.id == oldRouteID)
        #expect(session.state.evChargingStops == oldEVStops)
        var preferences = oldPreferences
        preferences.avoidHighways = true
        await session.applyVoicePreferences(preferences)
        #expect(session.state.routingPreferences == oldPreferences)
        #expect(session.state.route?.id == oldRouteID)
        #expect(session.state.errorMessage?.contains("Przywrócono") == true)
    }

    @Test
    func invalidOrStaleGPSRejectsMutationBeforeProviderRequest() async throws {
        for invalid in [Double.nan, -1, 100] {
            let session = makeSession()
            let oldDestination = session.state.destination
            session.state.location?.accuracy = invalid
            await session.replaceVoiceDestination(Destination(name: "Inny cel", coordinate: .init(latitude: 52.03, longitude: 21)))
            #expect(session.state.destination == oldDestination)
            #expect(session.state.status == .navigating)
        }
        let session = makeSession()
        let stops = session.state.waypoints
        let first = try #require(stops.first)
        session.state.location?.timestamp = Date().addingTimeInterval(-60)
        await session.removeVoiceWaypoint(first.id)
        #expect(session.state.waypoints == stops)
        #expect(session.state.errorMessage?.contains("GPS") == true)
    }

    @Test
    func failedAdditionRestoresPriorityStopsAndTripWaypoints() async {
        let session = makeSession()
        let stops = session.state.waypoints
        let pending = session.state.pendingWaypointIDs
        await session.addVoiceWaypoint(Destination(name: "Dodawany postój",
            coordinate: .init(latitude: 52.003, longitude: 21)))
        #expect(session.state.waypoints == stops)
        #expect(session.state.pendingWaypointIDs == pending)
        #expect(session.tripSession?.waypoints == stops)
        #expect(session.state.status == .navigating)
        #expect(session.state.errorMessage?.contains("Przywrócono") == true)
    }

    @Test
    func previewWithExplicitOriginNeedsNoGPSAndFailureRestoresItsRoute() async throws {
        let session = makeSession()
        let provider = VoiceCapturingFailureProvider()
        session.routeProvider = provider
        session.state.status = .routePreview
        session.tripSession = nil
        session.state.location = nil
        let origin = Destination(name: "Zaplanowany początek", coordinate: .init(latitude: 51, longitude: 20))
        session.state.routeOrigin = RoutePoint(origin, source: .search)
        let oldRouteID = session.state.route?.id
        let arrival = Date().addingTimeInterval(2_000)
        session.state.estimatedArrival = arrival
        session.state.progress = RouteProgress(traveledDistance: 0, remainingDistance: 2_224,
            remainingTime: 2_000, distanceToNextManeuver: 100, nextManeuver: nil,
            geometryProgress: 0, geometryRouteID: oldRouteID)
        let oldPreferences = session.state.routingPreferences
        let oldStops = session.state.waypoints
        _ = await session.voiceRouteEstimate(preferences: oldPreferences)
        #expect(provider.lastOrigin == origin.coordinate)
        #expect(provider.lastStops == oldStops.map(\.coordinate))
        var preferences = oldPreferences
        preferences.avoidTolls = true
        await session.applyVoicePreferences(preferences)
        #expect(provider.requestCount >= 2)
        #expect(session.state.route?.id == oldRouteID)
        #expect(session.state.status == .routePreview)
        #expect(session.state.routingPreferences == oldPreferences)
        #expect(session.state.waypoints == oldStops)
        #expect(session.state.routeOrigin?.coordinate == origin.coordinate)
        #expect(session.state.estimatedArrival == arrival)
        #expect(session.state.progress?.remainingTime == 2_000)
        #expect(session.state.progress?.geometryRouteID == oldRouteID)
        #expect(session.state.errorMessage?.contains("Przywrócono") == true)
    }

    @Test
    func failedOldRequestCannotRollBackExternallySelectedDestination() async throws {
        let session = makeSession()
        let provider = VoiceSuspendedFailureProvider()
        session.routeProvider = provider
        let first = try #require(session.nextVoiceWaypoint)
        let operation = Task { await session.removeVoiceWaypoint(first.id) }
        await provider.waitUntilRequested()
        let replacement = Destination(name: "Nowy plan", coordinate: .init(latitude: 53, longitude: 20))
        session.selectDestination(replacement, applyConfiguredMode: false)
        provider.fail()
        await operation.value
        #expect(session.state.destination == replacement)
        #expect(session.state.status == .destinationPreview)
        #expect(session.state.waypoints.isEmpty)
        #expect(session.state.errorMessage == nil)
    }

    private func makeSession() -> NavigationSession {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.routeProvider = VoiceFailureProvider()
        session.trafficProvider = nil
        session.voice.setEnabled(false)
        session.state.voiceEnabled = false
        session.state.transportMode = .walking
        session.state.routingPreferences = RoutingPreferences()
        let start = Coordinate(latitude: 52, longitude: 21)
        let end = Coordinate(latitude: 52.02, longitude: 21)
        let destination = Destination(name: "Cel", coordinate: end)
        let route = NavigationRoute(coordinates: [start, end], distance: 2_224,
                                    expectedTravelTime: 2_000, maneuvers: [])
        session.state.route = route
        session.state.routeOptions = [route]
        session.state.destination = destination
        session.state.status = .navigating
        session.state.gpsQuality = .good
        session.state.waypoints = [
            Destination(name: "Pierwszy postój", coordinate: .init(latitude: 52.005, longitude: 21)),
            Destination(name: "Drugi postój", coordinate: .init(latitude: 52.01, longitude: 21))
        ]
        session.state.evChargingStops = [Destination(name: "Ładowarka", coordinate: .init(latitude: 52.015, longitude: 21))]
        if let first = session.state.waypoints.first {
            session.state.waypointNavigationTargets[first.id] = POINavigationTarget(
                coordinate: first.coordinate, type: .frontEntrance, confidence: 1)
        }
        session.tripSession = TripSession(destination: destination, waypoints: session.state.waypoints,
            originalExpectedTravelTime: 2_000, startedAt: Date(), lastLocation: nil,
            tracksDriving: false, transportMode: .walking)
        advance(session, alongRoute: 100, latitude: 52.0009)
        return session
    }

    private func advance(_ session: NavigationSession, alongRoute: Double, latitude: Double) {
        let now = Date()
        let coordinate = Coordinate(latitude: latitude, longitude: 21)
        session.state.location = NavigationLocation(coordinate: coordinate, speed: 1.5,
            course: 0, accuracy: 5, timestamp: now)
        guard let route = session.state.route else { return }
        let projection = RouteProjection(coordinate: coordinate, distanceFromRoute: 0, alongRoute: alongRoute, segment: 0)
        session.state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: now,
            match: RouteMatch(projection: projection, confidence: 1))
        session.previousRouteMatch = (route.id, projection, now)
    }
}

@MainActor
private struct VoiceFailureProvider: AdvancedRouteProvider {
    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        throw RoutingError.network
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        throw RoutingError.network
    }
    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }
}

@MainActor
private final class VoiceCapturingFailureProvider: AdvancedRouteProvider {
    var lastOrigin: Coordinate?
    var lastStops: [Coordinate] = []
    var requestCount = 0
    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        lastOrigin = from
        requestCount += 1
        throw RoutingError.network
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        lastStops = through
        return try await calculateRoutes(from: from, to: to, mode: mode)
    }
    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }
}

@MainActor
private final class VoiceSuspendedFailureProvider: AdvancedRouteProvider {
    private var response: CheckedContinuation<[NavigationRoute], Error>?
    private var requested: CheckedContinuation<Void, Never>?
    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func fail() { response?.resume(throwing: RoutingError.network); response = nil }
    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        try await withCheckedThrowingContinuation {
            response = $0
            requested?.resume()
            requested = nil
        }
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, mode: mode)
    }
    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }
}
#endif
