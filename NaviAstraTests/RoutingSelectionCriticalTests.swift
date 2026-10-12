import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct RoutingSelectionCriticalTests {
    private let road = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.03, longitude: 21)]

    @Test func preferencesSurvivePersistenceAndRankingPreservesActualETA() throws {
        var preferences = try JSONDecoder().decode(RoutingPreferences.self, from: Data("{\"advanced\":{\"shortest\":true}}".utf8))
        #expect(preferences.advanced.effectiveRoutePreference == .shortest)
        preferences.advanced.shortest = false
        preferences.advanced.routePreference = .balanced
        let decoded = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.advanced.effectiveRoutePreference == .balanced)
        var payload: [String: Any] = [:]
        try decoded.applyValhallaOptions(to: &payload, mode: .car)
        #expect((payload["costing_options"] as? [String: [String: Any]])?["auto"]?["shortest"] as? Bool == false)
        let busy = NavigationRoute(coordinates: road, distance: 19_000, expectedTravelTime: 31 * 60,
            maneuvers: (0..<41).map { _ in Maneuver(shapeIndex: 0, instruction: "Skręt", type: 10) })
        let easy = NavigationRoute(coordinates: road, distance: 22_000, expectedTravelTime: 33 * 60,
            maneuvers: (0..<8).map { _ in Maneuver(shapeIndex: 0, instruction: "Skręt", type: 10) })
        #expect(RouteScoringEngine.ranked([busy, easy], preference: .fastest).first?.id == busy.id)
        #expect(RouteScoringEngine.ranked([busy, easy], preference: .balanced).first?.id == easy.id)
        #expect(RouteScoringEngine.ranked([easy, busy], preference: .shortest).first?.id == busy.id)
        #expect(RouteScoringEngine.score(easy).travelTime == 33 * 60)
        #expect(RouteScoringEngine.score(easy).trafficDelay == nil)
        #expect(RouteScoringEngine.score(easy).roadQualityCost == nil)
        var knownRough = easy
        knownRough.id = UUID()
        knownRough.maneuvers = [Maneuver(shapeIndex: 0, instruction: "Droga gruntowa", type: 8,
            information: ManeuverInformation(distanceMeters: 2_000, rough: true))]
        #expect(RouteScoringEngine.score(knownRough).roadQualityCost == 60)
        // Unknown quality on another route disables that component for the comparison.
        #expect(RouteScoringEngine.ranked([knownRough, easy], preference: .balanced).first?.id == knownRough.id)
        knownRough.maneuvers[0].information?.distanceMeters = nil
        #expect(RouteScoringEngine.score(knownRough).roadQualityCost == nil)
        let stale = TrafficSnapshot(flow: nil, incidents: [], updatedAt: Date().addingTimeInterval(-300),
                                    partialError: nil, incidentDataAvailable: true)
        #expect(RouteScoringEngine.score(easy, traffic: stale).trafficDelay == nil)

    }

    @Test func diversityKeepsTheRecommendedRouteAndDistinctRoadsAndChargingStops() {
        let first = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 300, maneuvers: [])
        let duplicate = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 301, maneuvers: [])
        let via = [road[0], Coordinate(latitude: 52.015, longitude: 21.01), road[1]]
        let other = NavigationRoute(coordinates: via, distance: 3_700, expectedTravelTime: 320, maneuvers: [])
        let kept = RouteSimilarity.diverse([first, duplicate, other])
        #expect(kept.map(\.id) == [first.id, other.id])
        #expect(RouteSimilarity.overlap(first, duplicate) > 0.99)
        #expect(RouteSimilarity.overlap(first, other) < 0.8)
        var ev = duplicate
        ev.chargingStops = [EVChargingStop(id: "charger", destination: Destination(name: "Ładowarka", coordinate: road[0]),
            connectorTypes: ["ccs"], maximumPowerKW: 100, estimatedChargingTime: 600,
            availabilityKnown: false, publicAccess: true)]
        #expect(RouteSimilarity.diverse([first, ev]).count == 2)
        let reverse = NavigationRoute(coordinates: Array(road.reversed()), distance: 3_330,
                                      expectedTravelTime: 300, maneuvers: [])
        #expect(RouteSimilarity.overlap(first, reverse) < 0.01)
    }

    @Test func samplingAdaptsToRoadsAndIncidentsWithinTheRequestBudget() {
        var city = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 900, maneuvers: [])
        let highway = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 100,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź", type: 8,
                                 information: ManeuverInformation(highway: true))])
        let geometry = RouteProgressGeometry(city)
        let dense = RouteTrafficMonitor.flowQueries(for: city, from: 0, through: geometry.length)
        let sparse = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length)
        #expect(dense.count > sparse.count)
        let measured = RouteTrafficSegment(id: "local-road", routeID: highway.id, startDistance: 0,
            endDistance: geometry.length, coordinates: road, colorHex: 0, isRoadClosure: false, roadClass: "FRC6")
        let local = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length,
                                                     measuredSegments: [measured])
        #expect(local.count > sparse.count)

        let incident = TrafficIncident(id: "jam", description: "Korek", coordinate: road[0], delaySeconds: 90,
            category: .jam, severity: .moderate, geometry: [Coordinate(latitude: 52.012, longitude: 21),
                                                        Coordinate(latitude: 52.014, longitude: 21)])
        let focused = RouteTrafficMonitor.flowQueries(for: highway, from: 0, through: geometry.length,
                                                       incidents: [incident])
        #expect(focused.count > sparse.count)
        city.coordinates = [road[0], Coordinate(latitude: 53, longitude: 21)]
        city.distance = 111_000; city.expectedTravelTime = 20_000
        let budget = RouteTrafficMonitor.flowQueries(for: city, from: 0, through: city.distance)
        #expect(budget.count <= RouteTrafficMonitor.maximumFlowSamples)
        #expect(budget.first?.distanceAlongRoute == 0)
        #expect((budget.last?.distanceAlongRoute ?? 0) > 100_000)
        #expect(zip(budget, budget.dropFirst()).allSatisfy { $0.distanceAlongRoute < $1.distanceAlongRoute })
    }

    @Test func identityAndDirectionAgreeAcrossWarningsTrafficAndETA() {
        let route = NavigationRoute(coordinates: road, distance: 3_330, expectedTravelTime: 300,
            maneuvers: [Maneuver(shapeIndex: 0, instruction: "Jedź A2", type: 8, streetNames: ["A2", "E30"])])
        let geometry = RouteProgressGeometry(route)
        func incident(_ ref: String, _ direction: TrafficGeometryDirection = .unknown) -> TrafficIncident {
            TrafficIncident(id: ref, description: "Zamknięcie", coordinate: road[0], delaySeconds: nil,
                category: .roadClosed, severity: .major, geometry: road,
                roadNumbers: [ref], geometryDirection: direction)
        }
        for (ref, accepted) in [("A2", true), ("E 30", true), ("A4", false), ("E50", false), ("S8", true), ("", true)] {
            let event = incident(ref)
            #expect((RouteTrafficMonitor.incidentProjection(event, geometry: geometry, route: route) != nil) == accepted)
            let snapshot = TrafficSnapshot(flow: nil, incidents: [event], updatedAt: .now,
                                            partialError: nil, incidentDataAvailable: true)
            let matched = RouteTrafficMonitor.matching([event], to: route, from: 0,
                through: geometry.length, routeGeometry: geometry)
            #expect(!matched.isEmpty == accepted)
            if accepted { #expect(matched.first?.roadNumbers == event.roadNumbers) }
            // The event starts at the origin; moving it ahead exercises the ETA closure rule.
            let ahead = TrafficIncident(id: ref, description: event.description,
                coordinate: Coordinate(latitude: 52.005, longitude: 21), delaySeconds: nil,
                category: .roadClosed, severity: .major,
                geometry: [Coordinate(latitude: 52.005, longitude: 21), road[1]], roadNumbers: [ref])
            let traffic = TrafficSnapshot(flow: nil, incidents: [ahead], updatedAt: snapshot.updatedAt,
                                           partialError: nil, incidentDataAvailable: true)
            #expect(RoadRouteETA.estimate(route, from: 0, traffic: traffic).isFinite != accepted)
        }
        #expect(RouteTrafficMonitor.incidentProjection(incident("A2", .backward), geometry: geometry, route: route) == nil)
    }

    @Test func fullClosureRejectsSparseCrossingsAndMergesUserExclusions() throws {
        let closed = [Coordinate(latitude: 52.005, longitude: 21), Coordinate(latitude: 52.025, longitude: 21)]
        let avoidance = try RoadClosureAvoidance(geometry: closed)
        let crossing = NavigationRoute(coordinates: [Coordinate(latitude: 52.015, longitude: 20.99),
            Coordinate(latitude: 52.015, longitude: 21.01)], distance: 1_400, expectedTravelTime: 100, maneuvers: [])
        #expect(avoidance.intersects(crossing)) // Both vertices are far from the closed road.
        let beyond = NavigationRoute(coordinates: [Coordinate(latitude: 52.03, longitude: 20.99),
            Coordinate(latitude: 52.03, longitude: 21.01)], distance: 1_400, expectedTravelTime: 100, maneuvers: [])
        #expect(!avoidance.intersects(beyond))
        let detour = NavigationRoute(coordinates: [Coordinate(latitude: 52.004, longitude: 21.001),
            Coordinate(latitude: 52.026, longitude: 21.001)], distance: 2_400, expectedTravelTime: 100, maneuvers: [])
        #expect(!avoidance.intersects(detour))
        var preferences = RoutingPreferences()
        preferences.advanced.avoidAreas = [ValhallaAvoidArea(name: "Obszar", vertices: [
            Coordinate(latitude: 51, longitude: 20), Coordinate(latitude: 51.001, longitude: 20),
            Coordinate(latitude: 51.001, longitude: 20.001)])]
        try RoadRoutingContext.$closurePolygons.withValue(avoidance.polygons) {
            var payload: [String: Any] = [:]
            try preferences.applyValhallaOptions(to: &payload, mode: .car)
            let polygons = payload["exclude_polygons"] as? [[[Double]]]
            #expect(polygons?.count == avoidance.polygons.count + 1)
            #expect(polygons?.last?.first == polygons?.last?.last)
        }
        #expect(RoadRoutingContext.closurePolygons.isEmpty)
    }
}
