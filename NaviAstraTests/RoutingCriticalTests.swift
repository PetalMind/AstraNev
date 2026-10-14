import Foundation
import Testing
@testable import NaviAstra

/// Regressions in navigation decisions and EV reachability, not UI behavior.
@MainActor
struct RoutingCriticalTests {
    @Test func detailedRoadEventsPreserveEvidenceAndSeparateSafetyFromRouting() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = #"""
        {"incidents":[{"geometry":{"type":"LineString","coordinates":[[21,52],[21,52.01]]},
        "properties":{"id":"closure","iconCategory":"roadClosed","magnitudeOfDelay":"major",
        "events":[{"code":401,"description":"Droga zamknięta","iconCategory":"roadClosed"},
        {"code":99999,"description":"Przedmioty na jezdni","iconCategory":"dangerousConditions"}],
        "startTime":"2020-01-01T00:00:00Z","endTime":"2040-01-01T00:00:00.000Z",
        "numberOfReports":3,"lastReportTime":"2020-01-01T00:00:00Z","probabilityOfOccurrence":"probable"}}]}
        """#
        let closure = try #require(TomTomTrafficProvider.decodeIncidents(Data(json.utf8), observedAt: now).first)
        #expect(closure.events.map(\.code) == [401, 99999])
        #expect(closure.detailDescriptions == ["Przedmioty na jezdni"])
        #expect(closure.isRoadClosure)
        #expect(closure.community?.numberOfReports == 3)
        #expect(closure.expiresAt != nil)
        #expect(try TomTomTrafficProvider.decodeIncidents(Data(json.utf8),
            observedAt: Date(timeIntervalSince1970: 2_300_000_000)).isEmpty)
        let route = NavigationRoute(coordinates: closure.geometry, distance: 1_112,
            expectedTravelTime: 100, maneuvers: [])
        let matched = try #require(RouteTrafficMonitor.matching([closure], to: route, from: 0,
            through: 1_112, routeGeometry: RouteProgressGeometry(route)).first)
        #expect(matched.events.map(\.code) == closure.events.map(\.code))
        #expect(matched.expiresAt == closure.expiresAt)
        #expect(matched.community?.numberOfReports == 3)
        // Explicit informational causes must never turn into a closure or ETA penalty.
        let police = TrafficIncident(id: "police", description: "Kontrola policyjna",
            coordinate: route.coordinates.last!, delaySeconds: 900,
            category: .roadClosed, severity: .major, cause: .policeCheckpoint)
        #expect(!police.isRoadClosure)
        #expect(police.routingDelaySeconds == nil)
        #expect(SafetyAlertEngine.alerts(in: [police], at: now).count == 1)
        let snapshot = TrafficSnapshot(flow: nil, incidents: [police], updatedAt: .now,
            partialError: nil, incidentDataAvailable: true)
        #expect(abs(RoadRouteETA.estimate(route, from: 0, traffic: snapshot) - 100) < 0.001)
        let expired = TrafficIncident(id: "expired", description: "Wypadek", coordinate: police.coordinate,
            delaySeconds: 900, category: .accident, severity: .major, expiresAt: .distantPast)
        #expect(SafetyAlertEngine.alerts(in: [expired], at: now).isEmpty)
        #expect(RouteTrafficMonitor.incidentProjection(expired, geometry: RouteProgressGeometry(route)) == nil)
    }

    @Test func osmRestrictionsPreserveEmbeddedValuesAndConditionalMeaning() throws {
        let height = try #require(OSMHeightRestriction.parse(["traffic_sign": "PL:B-16[3,5];B-18[12]" ]))
        #expect(height.value == "3,5 m")
        #expect(height.source == .explicitTrafficSign)
        let weight = OSMWeightRestriction.parse(["traffic_sign": "PL:B-16[3,5];B-18[12]"])
        #expect(weight.first?.value == "12 t")
        #expect(OSMHeightRestriction.parse(["maxheight:physical": "3.5"]) == nil)
        // Conditional-only restrictions may appear on the map, but cannot become unconditional route alerts.
        let tags = ["maxheight:conditional": "3.5 @ (Mo-Fr 08:00-18:00)"]
        #expect(OSMHeightRestriction.parse(tags) == nil)
        let conditional = try #require(OSMHeightRestriction.parse(tags, includeConditional: true))
        #expect(conditional.value == nil)
        #expect(conditional.condition == tags["maxheight:conditional"])
        #expect(OSMWeightRestriction.parse(["hgv:conditional": "no @ (Su)"]).isEmpty)
        let trucks = OSMWeightRestriction.parse(["hgv:conditional": "no @ (Su)"], includeConditional: true)
        #expect(trucks.first?.condition == "no @ (Su)")
        #expect(trucks.first?.value == nil)
        #expect(OSMWeightRestriction.parse(["hgv:conditional": "yes @ (Su)"], includeConditional: true).isEmpty)
    }

    @Test func remainingETAUsesSegmentTimesAndMeasuredTrafficWithoutDoubleCounting() throws {
        let coordinates = [Coordinate(latitude: 52, longitude: 21),
                           Coordinate(latitude: 52.01, longitude: 21),
                           Coordinate(latitude: 52.02, longitude: 21)]
        var route = NavigationRoute(coordinates: coordinates, distance: 2_224,
                                    expectedTravelTime: 1_000, maneuvers: [])
        let length = RouteProgressGeometry(route).length
        let half = length / 2
        route.travelSegments = [RouteTravelSegment(startDistance: 0, endDistance: half, duration: 100),
                                RouteTravelSegment(startDistance: half, endDistance: length, duration: 900)]
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: nil) - 900) < 0.001)
        let segment = RouteTrafficSegment(id: "flow", routeID: route.id, startDistance: half,
            endDistance: length, coordinates: Array(coordinates.suffix(2)), colorHex: 0,
            isRoadClosure: false, currentSpeedKph: half / 1_800 * 3.6, freeFlowSpeedKph: 50)
        let incident = TrafficIncident(id: "jam", description: "Korek", coordinate: coordinates[2],
            delaySeconds: 600, category: .jam, severity: .major, distanceAlongRoute: length)
        let traffic = TrafficSnapshot(flow: nil, incidents: [incident], routeFlowSegments: [segment],
                                      updatedAt: Date(), partialError: nil, incidentDataAvailable: true)
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: traffic) - 1_800) < 0.001)
        let stale = TrafficSnapshot(flow: nil, incidents: [incident], routeFlowSegments: [segment],
                                    updatedAt: Date().addingTimeInterval(-300), partialError: nil,
                                    incidentDataAvailable: true)
        #expect(abs(RoadRouteETA.estimate(route, from: half, traffic: stale) - 900) < 0.001)
        // The navigation cache must preserve the same decisions throughout a trip,
        // including stale measurements, closures, a replaced route, and a reset.
        var tracker = RouteProgressTracker()
        for distance in [0, half / 2, half, length - 10] {
            for snapshot in [nil, traffic, stale] {
                let expected = RoadRouteETA.estimate(route, from: distance, traffic: snapshot, paceMultiplier: 1.2)
                let cached = tracker.estimateRoadETA(route: route, from: distance,
                    traffic: snapshot, paceMultiplier: 1.2)
                #expect(abs(cached - expected) < 0.001)
            }
        }
        let closed = RouteTrafficSegment(id: "closed", routeID: route.id, startDistance: half,
            endDistance: length, coordinates: Array(coordinates.suffix(2)), colorHex: 0,
            isRoadClosure: true, currentSpeedKph: nil, freeFlowSpeedKph: nil)
        let closure = TrafficSnapshot(flow: nil, incidents: [], routeFlowSegments: [closed],
            updatedAt: .now, partialError: nil, incidentDataAvailable: true)
        #expect(!tracker.estimateRoadETA(route: route, from: 0, traffic: closure).isFinite)
        #expect(tracker.estimateRoadETA(route: route, from: 0, traffic: nil).isFinite)
        let replacement = NavigationRoute(coordinates: coordinates, distance: length,
            expectedTravelTime: 250, maneuvers: [])
        #expect(abs(tracker.estimateRoadETA(route: replacement, from: 0, traffic: nil) - 250) < 0.001)
        route.travelSegments = []
        tracker.invalidateRoadGeometry()
        #expect(abs(tracker.estimateRoadETA(route: route, from: half, traffic: nil) - 500) < 0.001)

        // Cropping colored geometry must keep the GPS boundary and every road bend.
        let geometry = RouteProgressGeometry(route)
        let parts = RouteTrafficMapGeometry.coloredLine(geometry, from: half / 2, through: length,
            segments: [segment], defaultColor: 0x123456)
        #expect(parts.map(\.colorHex) == [0x123456, segment.colorHex])
        #expect(parts.first?.coordinates.first == geometry.coordinate(at: half / 2))
        #expect(parts.first?.coordinates.last == parts.last?.coordinates.first)
        #expect(parts.last?.coordinates.last == coordinates.last)
        #expect(geometry.corridor(from: half, through: length) == Array(coordinates.suffix(2)))
        #expect(geometry.corridor(from: length, through: length).isEmpty)
        #expect(geometry.firstVertex(after: length) == coordinates.count)
        let reverse = RouteProjection(coordinate: coordinates[0], distanceFromRoute: 0, alongRoute: 0, segment: 0)
        #expect(!RoadRouteETA.canFollow(route, projection: reverse, heading: 180))
    }

    @Test func evPlansReachableStationsBeyondOldCutoffAndRetainsFallbacks() {
        func charger(_ id: String, _ position: Double, _ power: Double) -> NearbyPlaceCandidate {
            NearbyPlaceCandidate(id: id,
                destination: Destination(name: id, coordinate: Coordinate(latitude: 52, longitude: 21)),
                category: .charging, distanceFromRoute: position,
                chargingStation: ChargingStationCapabilities(connectorTypes: ["ccs"], maximumPowerKW: power,
                    chargingPointCount: 1, publicAccess: true, availability: .unknown))
        }
        let stations = [charger("early", 180_000, 50), charger("reachable", 220_000, 150)]
        let plans = EVStopPlanner.plans(chargers: stations, routeLength: 400_000,
                                       initialRange: 300_000, fullRange: 300_000,
                                       consumption: 18, maximumPower: 150)
        #expect(plans.contains { $0.map(\.id) == ["reachable"] })
        #expect(plans.contains { $0.map(\.id) == ["early"] })
        #expect(EVStopPlanner.plans(chargers: [charger("unreachable", 250_000, 150)],
            routeLength: 400_000, initialRange: 300_000, fullRange: 300_000,
            consumption: 18, maximumPower: 150).isEmpty)
        let lowSOC = EVStopPlanner.chargingTime(from: 0.2, to: 0.4, batteryKWh: 60, power: 100)
        let highSOC = EVStopPlanner.chargingTime(from: 0.8, to: 1, batteryKWh: 60, power: 100)
        #expect(highSOC > lowSOC)
        #expect(lowSOC > 12 / 100 * 3_600 + 300)
    }

    @Test func supersededRoadRequestsRejectResultsAndCancelTheirWork() async throws {
        let token = TransitPlanningCancellationToken()
        let child = Task { () throws -> Void in
            try await RoadRoutingContext.$cancellationToken.withValue(token) {
                token.cancel()
                // Even cancellation registered after a superseding request must fire immediately.
                let cancelledTask = Task { try await Task.sleep(for: .seconds(30)) }
                let handler = token.addCancellationHandler { cancelledTask.cancel() }
                defer { token.removeCancellationHandler(handler) }
                do { try await cancelledTask.value; Issue.record("Superseded work continued") }
                catch is CancellationError { }
                try RoadRoutingContext.checkCancellation()
            }
        }
        do { try await child.value; Issue.record("Cancelled result accepted") }
        catch is CancellationError { }
    }
    @Test func trafficDecisionsRejectAdjacentAndCrossingClosuresAcrossETAAndGuidance() {
        let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.01, longitude: 21)]
        let route = NavigationRoute(coordinates: road, distance: 1_112, expectedTravelTime: 100, maneuvers: [])
        let geometry = RouteProgressGeometry(route)
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        let neighboring = [Coordinate(latitude: 52.002, longitude: 21.0004),
                           Coordinate(latitude: 52.008, longitude: 21.0004)]
        let crossing = [Coordinate(latitude: 52.005, longitude: 20.999),
                        Coordinate(latitude: 52.005, longitude: 21.001)]
        let onRoad = [Coordinate(latitude: 52.002, longitude: 21), Coordinate(latitude: 52.008, longitude: 21)]
        for (index, points) in [neighboring, crossing, [onRoad[0]], onRoad].enumerated() {
            let incident = TrafficIncident(id: "closure-\(index)", description: "Zamknięcie",
                coordinate: points[0], delaySeconds: nil, category: .roadClosed, severity: .major,
                geometry: points)
            let accepted = index == 3
            #expect((RouteTrafficMonitor.incidentProjection(incident, geometry: geometry) != nil) == accepted)
            #expect((session.distanceToTrafficIncident(incident, on: route, after: 0) != nil) == accepted)
            let snapshot = TrafficSnapshot(flow: nil, incidents: [incident], updatedAt: .now,
                                           partialError: nil, incidentDataAvailable: true)
            #expect(RoadRouteETA.estimate(route, from: 0, traffic: snapshot).isFinite != accepted)
            #expect(RouteTrafficMonitor.matching([incident], to: route, from: 0, through: geometry.length,
                                                 routeGeometry: geometry).isEmpty != accepted)
        }
    }

    @Test func roadSignDecisionsRequireTheDriversRoadAndApproach() {
        let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.01, longitude: 21)]
        let position = Coordinate(latitude: 52.005, longitude: 21)
        let sideRoad = [Coordinate(latitude: 52.005, longitude: 20.999),
                        Coordinate(latitude: 52.005, longitude: 21.001)]
        let forward = RoadSignRouteContext(road: road, forward: true, travelBearing: nil)
        let reverse = RoadSignRouteContext(road: road, forward: false, travelBearing: nil)
        let side = RoadSignRouteContext(road: sideRoad, forward: nil, travelBearing: nil)
        let alerts = [forward, reverse, side].enumerated().map { index, context in
            RoadSafetyAlert(id: "stop-\(index)", type: .stopSign, coordinate: position,
                            source: .openStreetMap, signRouteContext: context)
        } + [RoadSafetyAlert(id: "ambiguous", type: .stopSign, coordinate: position, source: .openStreetMap)]
        let snapshot = RoadDataSnapshot(speedSegments: [], alerts: alerts, fetchedAt: .now)
        #expect(snapshot.matchedAlerts(on: road).map(\.id) == ["stop-0"])
        #expect(snapshot.matchedAlerts(on: Array(road.reversed())).map(\.id) == ["stop-1"])
    }

    @Test func carSelectionHonorsDistanceAndDoesNotInventSignalDelays() {
        let points = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.01, longitude: 21)]
        let short = NavigationRoute(coordinates: points, distance: 1_112, expectedTravelTime: 1_000,
                                    maneuvers: [], trafficSignalCount: 10)
        let fast = NavigationRoute(coordinates: points, distance: 1_300, expectedTravelTime: 660,
                                   maneuvers: [], trafficSignalCount: nil)
        #expect(RouteScoringEngine.ranked([short, fast], preference: .fastest).first?.id == fast.id)
        #expect(RouteScoringEngine.ranked([fast, short], preference: .shortest).first?.id == short.id)
        #expect(RouteScoringEngine.score(short).travelTime == short.expectedTravelTime)
        #expect(RouteScoringEngine.score(short).tollCost == nil)
        #expect(RouteScoringEngine.score(short).reliabilityCost == nil)
    }

    @Test func enforcementRequiresTheMeasuredRoadAndTravelDirection() {
        let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.01, longitude: 21)]
        let device = Coordinate(latitude: 52.005, longitude: 21)
        let serviceRoad = road.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude + 0.00008) }
        let expressway = OSMRoadSpeedSegment(id: 1, coordinates: road, tags: ["oneway": "yes"])
        let service = OSMRoadSpeedSegment(id: 2, coordinates: serviceRoad, tags: ["highway": "service"])
        let context = RoadSignRouteContext(road: road, forward: true, travelBearing: nil, roadID: 1)
        let types: [RoadAlertType] = [.speedCamera, .redLightCamera, .averageSpeedStart, .stopSign]
        for type in types {
            let alert = RoadSafetyAlert(id: type.rawValue, type: type, coordinate: device,
                                        source: .openStreetMap, signRouteContext: context)
            let snapshot = RoadDataSnapshot(speedSegments: [], alerts: [alert], fetchedAt: .now,
                                            roadSegments: [expressway, service])
            #expect(snapshot.matchedAlerts(on: road).count == 1)
            #expect(snapshot.matchedAlerts(on: serviceRoad).isEmpty)
            #expect(snapshot.matchedAlerts(on: Array(road.reversed())).isEmpty)
        }
        let unknown = RoadSafetyAlert(id: "official", type: .speedCamera, coordinate: device, source: .canard)
        #expect(RoadDataSnapshot(speedSegments: [], alerts: [unknown], fetchedAt: .now).matchedAlerts(on: road).isEmpty)
        let bidirectional = OSMRoadSpeedSegment(id: 1, coordinates: road, tags: [:])
        #expect(RoadDataSnapshot(speedSegments: [], alerts: [unknown], fetchedAt: .now,
                                roadSegments: [bidirectional]).matchedAlerts(on: road).isEmpty)
        let official = RoadDataSnapshot(speedSegments: [], alerts: [unknown], fetchedAt: .now,
                                        roadSegments: [expressway, service])
        #expect(official.matchedAlerts(on: road).count == 1)
        #expect(official.matchedAlerts(on: serviceRoad).isEmpty)
        let sectionStart = Coordinate(latitude: 52.002, longitude: 21)
        let sectionEnd = Coordinate(latitude: 52.008, longitude: 21)
        let section = [RoadSafetyAlert(id: "section-a", type: .averageSpeedStart, coordinate: sectionStart,
                                       source: .canard, sectionOtherEnd: sectionEnd),
                       RoadSafetyAlert(id: "section-b", type: .averageSpeedEnd, coordinate: sectionEnd,
                                       source: .canard, sectionOtherEnd: sectionStart)]
        let snapshot = RoadDataSnapshot(speedSegments: [], alerts: section, fetchedAt: .now,
                                        roadSegments: [expressway, service])
        #expect(snapshot.matchedAlerts(on: road).map(\.type) == [.averageSpeedStart, .averageSpeedEnd])
        #expect(snapshot.matchedAlerts(on: serviceRoad).isEmpty)
        #expect(snapshot.matchedAlerts(on: [device, road[1]]).map(\.type) == [.averageSpeedEnd])
    }

    @Test func safetyPresentationRejectsUncertainGPSAndAppliesLimitsAfterTheSign() throws {
        let state = NavigationState()
        let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.01, longitude: 21)]
        let route = NavigationRoute(coordinates: road, distance: 1_112, expectedTravelTime: 100, maneuvers: [])
        let location = NavigationLocation(coordinate: Coordinate(latitude: 52.005, longitude: 21),
                                          speed: 15, course: 0, accuracy: 5, timestamp: .now)
        let projection = try #require(MapMatcher.project(location.coordinate, onto: road))
        state.route = route
        state.status = .navigating
        state.location = location
        state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: location.timestamp,
                                                match: RouteMatch(projection: projection, confidence: 0.95))
        let context = RoadSignRouteContext(road: road, forward: true, travelBearing: nil)
        state.roadSafetyAlerts = [RoadSafetyAlert(id: "limit", type: .speedLimitSign,
            coordinate: location.coordinate, source: .openStreetMap, speedLimitKph: 70,
            distanceAlongRoute: projection.alongRoute + 100, signRouteContext: context)]
        #expect(MapDisplayPriorityEngine.upcomingAlerts(in: state).count == 1)
        #expect(MapDisplayPriorityEngine.passedSpeedLimit(in: state) == nil)
        state.roadSafetyAlerts[0].distanceAlongRoute = projection.alongRoute - 10
        #expect(MapDisplayPriorityEngine.upcomingAlerts(in: state).isEmpty)
        #expect(MapDisplayPriorityEngine.passedSpeedLimit(in: state) == 70)
        state.roadSafetyAlerts[0].signCode = "B-34"
        #expect(MapDisplayPriorityEngine.passedSpeedLimit(in: state) == nil)
        let nearbyRoad = road.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude + 0.00008) }
        state.roadAlertRoadSegments = [OSMRoadSpeedSegment(id: 1, coordinates: road, tags: ["oneway": "yes"]),
                                       OSMRoadSpeedSegment(id: 2, coordinates: nearbyRoad, tags: [:])]
        #expect(MapDisplayPriorityEngine.canPresentRouteAlerts(state))
        state.location?.coordinate.longitude += 0.00008
        #expect(!MapDisplayPriorityEngine.canPresentRouteAlerts(state))
        state.location = location
        state.location?.course = 180
        #expect(!MapDisplayPriorityEngine.canPresentRouteAlerts(state))
        state.location = location
        for (ambiguous, confidence, age) in [(true, 0.95, 0.0), (false, 0.2, 0.0), (false, 0.95, 30.0)] {
            state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: location.timestamp,
                match: RouteMatch(projection: projection, confidence: confidence), isAmbiguous: ambiguous)
            state.location?.timestamp = location.timestamp.addingTimeInterval(-age)
            #expect(!MapDisplayPriorityEngine.canPresentRouteAlerts(state))
            #expect(MapDisplayPriorityEngine.upcomingAlerts(in: state).isEmpty)
        }
    }

    @Test func lateOptimizationCannotRewriteANewTrip() async throws {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        let provider = SuspendedWaypointOptimizer()
        session.routeProvider = provider
        session.state.transportMode = .car
        let origin = Destination(name: "Start", coordinate: Coordinate(latitude: 52, longitude: 21))
        let oldDestination = Destination(name: "Old", coordinate: Coordinate(latitude: 52.03, longitude: 21))
        let newDestination = Destination(name: "New", coordinate: Coordinate(latitude: 53, longitude: 22))
        let stops = [Destination(name: "A", coordinate: Coordinate(latitude: 52.01, longitude: 21)),
                     Destination(name: "B", coordinate: Coordinate(latitude: 52.02, longitude: 21))]
        session.state.routeOrigin = RoutePoint(origin, source: .search)
        session.state.destination = oldDestination
        session.state.waypoints = stops
        session.state.status = .routePreview
        let optimization = Task { await session.optimizeWaypoints() }
        await provider.waitUntilRequested()
        session.selectDestination(newDestination, applyConfiguredMode: false)
        let replacement = [stops[1], stops[0]]
        session.state.waypoints = replacement
        provider.finish([1, 0])
        await optimization.value
        #expect(session.state.destination?.id == newDestination.id)
        #expect(session.state.waypoints == replacement)
        #expect(session.state.status == .destinationPreview)
        #expect(session.state.errorMessage == nil)
    }

}


@MainActor
private final class SuspendedWaypointOptimizer: AdvancedRouteProvider {
    private var result: CheckedContinuation<[Int], Error>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish(_ order: [Int]) { result?.resume(returning: order); result = nil }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination],
                                mode: TransportMode, preferences: RoutingPreferences) async throws -> [Int] {
        try await withCheckedThrowingContinuation {
            result = $0
            requested?.resume()
            requested = nil
        }
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        Issue.record("A stale optimization started another route request")
        throw RoutingError.invalidResponse
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, mode: mode)
    }
}
