#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct VoiceQuoteCriticalTests {
    @Test
    func futurePreviewUsesPlannedOriginTimeAndProposedPreferencesWithoutChangingPlan() async throws {
        let (session, provider) = makeSession()
        session.state.status = .routePreview
        session.state.location = nil
        session.state.transportMode = .walking
        let origin = Destination(name: "Początek", coordinate: .init(latitude: 51, longitude: 20))
        session.state.routeOrigin = RoutePoint(origin, source: .search)
        session.state.journeyTimeMode = .arriveBy
        let scheduled = Date(timeIntervalSince1970: 1_900_000_000)
        session.state.journeyTargetTime = scheduled
        let before = VoiceDialogContext(state: session.state)
        let oldTargets = session.state.waypointNavigationTargets
        let oldPreferences = session.state.routingPreferences
        var proposed = oldPreferences
        proposed.avoidHighways = true
        var requestedCoordinate: Coordinate?
        var requestedDate: Date?
        let result = await session.voiceRouteEstimate(preferences: proposed, planningTimeResolver: { mode, date, coordinate in
            #expect(mode == .arriveBy)
            requestedCoordinate = coordinate
            requestedDate = date
            return ValhallaPlanningTime(type: 2, value: "2030-03-17T16:00")
        })
        #expect(result == 240)
        #expect(requestedCoordinate == session.state.destination?.coordinate)
        #expect(requestedDate == scheduled)
        #expect(provider.origin == origin.coordinate)
        #expect(provider.planningTime?.type == 2)
        #expect(provider.planningTime?.value == "2030-03-17T16:00")
        #expect(provider.preferenceDate == scheduled)
        #expect(provider.preferences?.avoidHighways == true)
        #expect(provider.publishesAssessments == false)
        #expect(before.matches(session.state))
        #expect(session.state.routingPreferences == oldPreferences)
        #expect(session.state.waypointNavigationTargets == oldTargets)
    }

    @Test
    func activeQuoteForwardsConfirmedClosureAndRejectsRouteThroughIt() async throws {
        let (session, provider) = makeSession()
        session.state.transportMode = .car
        let closedRoad = [Coordinate(latitude: 52.009, longitude: 21), Coordinate(latitude: 52.011, longitude: 21)]
        let incident = TrafficIncident(id: "closed-road", description: "Zamknięcie", coordinate: closedRoad[0],
            delaySeconds: nil, category: .roadClosed, severity: .major, geometry: closedRoad, observedAt: .now)
        session.knownRoadClosures[incident.id] = ConfirmedRoadClosure(incident: incident, observedAt: .now, maximumAge: 120)
        let blocked = NavigationRoute(coordinates: [.init(latitude: 52, longitude: 21), .init(latitude: 52.02, longitude: 21)],
                                      distance: 2_224, expectedTravelTime: 100, maneuvers: [])
        let safe = NavigationRoute(coordinates: [.init(latitude: 52, longitude: 21), .init(latitude: 52.001, longitude: 21.003),
            .init(latitude: 52.019, longitude: 21.003), .init(latitude: 52.02, longitude: 21)],
            distance: 2_600, expectedTravelTime: 240, maneuvers: [])
        provider.routes = [blocked, safe]
        let oldRouteID = session.state.route?.id
        let estimate = await session.voiceRouteEstimate(preferences: session.state.routingPreferences)
        #expect(estimate == 240)
        #expect(!provider.closurePolygons.isEmpty)
        #expect(provider.planningTime == nil)
        #expect(session.state.route?.id == oldRouteID)
        #expect(session.knownRoadClosures.keys.contains(incident.id))
    }

    @Test
    func quoteUsesConsumedBatteryWithoutReplenishingRangeOrChangingChargingStops() async {
        let (session, provider) = makeSession()
        session.state.transportMode = .car
        var preferences = session.state.routingPreferences
        preferences.evPlanningEnabled = true
        preferences.evRangeKilometers = 400
        preferences.evBatteryPercent = 75
        session.state.routingPreferences = preferences
        if let destination = session.state.destination {
            session.tripSession = TripSession(destination: destination, waypoints: [],
                originalExpectedTravelTime: 240, startedAt: .now, lastLocation: nil,
                tracksDriving: false, transportMode: .car)
        }
        session.resetEVBatteryEstimate()
        session.tripSession?.distanceMeters = 500_000
        let oldStops = [Destination(name: "Planowana ładowarka", coordinate: .init(latitude: 52.005, longitude: 21))]
        session.state.evChargingStops = oldStops
        let estimate = await session.voiceRouteEstimate(preferences: preferences)
        #expect(estimate == nil)
        #expect(provider.requestCount == 0)
        #expect(session.availableEVRangeMeters(for: preferences) == 0)
        #expect(session.tripSession?.distanceMeters == 500_000)
        #expect(session.state.evChargingStops == oldStops)
    }

    @Test
    func evPreviewRecalculatesStopsInsteadOfTreatingPreviousChargersAsMandatory() async {
        let (session, provider) = makeSession()
        session.state.status = .routePreview
        session.state.transportMode = .car
        session.state.routeOrigin = RoutePoint(Destination(name: "Początek", coordinate: .init(latitude: 52, longitude: 21)), source: .search)
        var preferences = session.state.routingPreferences
        preferences.evPlanningEnabled = true
        preferences.evRangeKilometers = 400
        preferences.evBatteryPercent = 100
        session.state.routingPreferences = preferences
        let oldStops = [Destination(name: "Poprzednia ładowarka", coordinate: .init(latitude: 52.005, longitude: 21))]
        session.state.evChargingStops = oldStops
        let estimate = await session.voiceRouteEstimate(preferences: preferences)
        #expect(estimate == 240)
        #expect(provider.stops.isEmpty)
        #expect(session.state.evChargingStops == oldStops)
    }

    private func makeSession() -> (NavigationSession, VoiceQuoteProvider) {
        let session = NavigationSession(dependencies: .live(routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        let provider = VoiceQuoteProvider()
        session.routeProvider = provider
        session.trafficProvider = nil
        session.state.status = .navigating
        session.state.transportMode = .walking
        session.state.routingPreferences = RoutingPreferences()
        session.state.route = provider.routes.first
        session.state.destination = Destination(name: "Cel", coordinate: .init(latitude: 52.02, longitude: 21))
        session.state.location = NavigationLocation(coordinate: .init(latitude: 52, longitude: 21), speed: 1.5,
            course: 0, accuracy: 5, timestamp: .now)
        session.state.gpsQuality = .good
        return (session, provider)
    }
}

@MainActor
private final class VoiceQuoteProvider: AdvancedRouteProvider {
    var routes = [NavigationRoute(coordinates: [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.02, longitude: 21)],
                                 distance: 2_224, expectedTravelTime: 240, maneuvers: [])]
    var origin: Coordinate?
    var stops: [Coordinate] = []
    var planningTime: ValhallaPlanningTime?
    var preferenceDate: Date?
    var preferences: RoutingPreferences?
    var closurePolygons: [[[Double]]] = []
    var publishesAssessments = true
    var requestCount = 0
    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        requestCount += 1
        origin = from
        planningTime = RoadRoutingContext.planningTime
        preferenceDate = RoadRoutingContext.preferenceDate
        closurePolygons = RoadRoutingContext.closurePolygons
        publishesAssessments = RoadRoutingContext.publishesAssessments
        return routes
    }
    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        self.preferences = preferences
        stops = through
        return try await calculateRoutes(from: from, to: to, mode: mode)
    }
    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }
}
#endif
