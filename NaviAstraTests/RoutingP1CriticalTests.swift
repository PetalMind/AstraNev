import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct RoutingP1CriticalTests {
    let points = [Coordinate(latitude: 52, longitude: 21), Coordinate(latitude: 52.02, longitude: 21)]
    func route() -> NavigationRoute { NavigationRoute(coordinates: points, distance: 2_224, expectedTravelTime: 300, maneuvers: []) }

    @Test func coverageUnionsFreshIntervalsAndDoesNotTreatCorridorAsWholeJourney() {
        let route = route(), length = RouteProgressGeometry(route).length, now = Date()
        func segment(_ start: Double, _ end: Double, age: Double) -> RouteTrafficSegment {
            RouteTrafficSegment(id: String(start), routeID: route.id, startDistance: start, endDistance: end,
                coordinates: points, colorHex: 0, isRoadClosure: false, currentSpeedKph: 20,
                measuredAt: now.addingTimeInterval(-age))
        }
        let snapshot = TrafficSnapshot(flow: nil, incidents: [], routeFlowSegments: [
            segment(0, length * 0.4, age: 20), segment(length * 0.2, length * 0.5, age: 30),
            segment(length * 0.5, length, age: 300)], updatedAt: now, partialError: nil, incidentDataAvailable: true)
        let coverage = TrafficCoverage.measure(route: route, from: 0, through: length * 0.5, traffic: snapshot, now: now)
        #expect(abs(coverage.corridorFraction - 1) < 0.001)
        #expect(abs(coverage.routeFraction - 0.5) < 0.001)
        let reliability = RouteReliability.evaluate(route: route, from: 0, through: length * 0.5, traffic: snapshot, now: now)
        #expect(reliability.level == .strong)
        #expect(ETAConfidence.evaluate(reliability).level == .supported)
        #expect(ETAConfidence.evaluate(reliability).uncertaintySeconds == nil)
        let full = TrafficCoverage.measure(route: route, from: 0, traffic: snapshot, now: now)
        #expect(abs(full.observedDistance - length) < 0.001)
        #expect(abs(full.freshDistance - length * 0.5) < 0.001)
    }

    @Test func freshFlowDoesNotReviveExpiredClosureAndUnknownTrafficStaysUnknown() {
        let route = route(), now = Date(), length = RouteProgressGeometry(route).length
        let closure = TrafficIncident(id: "old", description: "Zamknięcie", coordinate: points[0], delaySeconds: nil,
            category: .roadClosed, severity: .major,
            geometry: [Coordinate(latitude: 52.005, longitude: 21), points[1]], observedAt: now.addingTimeInterval(-200))
        let flow = RouteTrafficSegment(id: "fresh", routeID: route.id, startDistance: 0, endDistance: length,
            coordinates: points, colorHex: 0, isRoadClosure: false, currentSpeedKph: 60, measuredAt: now)
        let snapshot = TrafficSnapshot(flow: nil, incidents: [closure], routeFlowSegments: [flow], updatedAt: now,
                                       partialError: nil, incidentDataAvailable: true)
        #expect(RoadRouteETA.estimate(route, from: 0, traffic: snapshot).isFinite)
        #expect(!RouteReliability.evaluate(route: route, from: 0, traffic: snapshot, now: now).hasConfirmedClosure)
        let missing = RouteReliability.evaluate(route: route, from: 0, traffic: nil)
        #expect(missing.trafficEvidence == nil)
        #expect(missing.level == .unavailable)
        #expect(RouteScoringEngine.score(route).reliabilityCost == nil)
        let expired = TrafficIncident(id: "expired", description: "Zamknięcie", coordinate: points[0], delaySeconds: nil,
            category: .roadClosed, severity: .major, geometry: [Coordinate(latitude: 52.005, longitude: 21), points[1]],
            observedAt: now, expiresAt: now.addingTimeInterval(-1))
        let ended = TrafficSnapshot(flow: nil, incidents: [expired], updatedAt: now, partialError: nil, incidentDataAvailable: true)
        #expect(RoadRouteETA.estimate(route, from: 0, traffic: ended).isFinite)
        #expect(!RouteReliability.evaluate(route: route, from: 0, traffic: ended, now: now).hasConfirmedClosure)

    }

    @Test func budgetIsLowerInPreviewAndBackgroundAndCanExpandForProblems() {
        let route = route(), length = RouteProgressGeometry(route).length
        let preview = TrafficSamplingBudget.resolved(isNavigating: false, isForeground: true, problemDetected: false)
        let driving = TrafficSamplingBudget.resolved(isNavigating: true, isForeground: true, problemDetected: false)
        let problem = TrafficSamplingBudget.resolved(isNavigating: true, isForeground: true, problemDetected: true)
        let background = TrafficSamplingBudget.resolved(isNavigating: true, isForeground: false, problemDetected: true)
        #expect(preview.maximumRequests == 40 && driving.maximumRequests == 64)
        #expect(problem.maximumRequests == 96 && background.maximumRequests == 24)
        let queries = RouteTrafficMonitor.flowQueries(for: route, from: 0, through: length, budget: background)
        #expect(queries.count <= 24)
    }

    @Test func matchingUsesDirectionAndContinuityAndReportsStationaryAmbiguity() {
        let loop = [points[0], points[1], Coordinate(latitude: points[1].latitude, longitude: 21.0002),
                    Coordinate(latitude: points[0].latitude, longitude: 21.0002)]
        let route = NavigationRoute(coordinates: loop, distance: 4_500, expectedTravelTime: 500, maneuvers: [])
        let geometry = RouteProgressGeometry(route), now = Date()
        let moving = NavigationLocation(coordinate: Coordinate(latitude: 52.01, longitude: 21.0001),
            speed: 15, course: 0, accuracy: 20, timestamp: now, courseAccuracy: 5)
        let directed = MapMatchingEngine.match(route: route, geometry: geometry, location: moving,
                                                previous: nil, previousTimestamp: nil, now: now)
        #expect(directed?.match.projection.segment == 0)
        #expect(directed?.ambiguous == false)
        var stopped = moving; stopped.speed = 0; stopped.course = -1
        let ambiguous = MapMatchingEngine.match(route: route, geometry: geometry, location: stopped,
                                                 previous: nil, previousTimestamp: nil, now: now)
        #expect(ambiguous?.ambiguous == true)
        #expect((ambiguous?.match.confidence ?? 1) < 0.4)
        if let ambiguous {
            let previous = RouteProjection(coordinate: points[0], distanceFromRoute: 0, alongRoute: 10, segment: 0)
            #expect(MapMatchingEngine.stableProgress(result: ambiguous, projection: ambiguous.match.projection,
                                                     previous: previous).alongRoute == 10)
            let puck = NavigationPuckEngine()
            puck.update(location: stopped, route: route, isNavigating: true,
                matchedRoute: NavigationRouteMatch(routeID: route.id, locationTimestamp: stopped.timestamp,
                    match: ambiguous.match, isAmbiguous: true), at: now)
            let waypoints = [Destination(name: "Przystanek", coordinate: Coordinate(latitude: 52.015, longitude: 21))]
            let trusted = MapMatchingEngine.stableProgress(result: ambiguous, projection: ambiguous.match.projection, previous: previous)
            let remaining = RemainingRouteWaypointPlanner.remainingStops(from: stopped.coordinate,
                routeCoordinates: loop, currentAlongRoute: trusted.alongRoute, stops: waypoints, routedCoordinates: [:])
            #expect(remaining.map(\.id) == waypoints.map(\.id))
            #expect(puck.frame(at: now)?.routeProgress == nil)
            #expect((puck.frame(at: now)?.coordinate.distance(to: stopped.coordinate) ?? 100) < 0.5)

        }

        stopped.timestamp = now.addingTimeInterval(-30)
        #expect(MapMatchingEngine.match(route: route, geometry: geometry, location: stopped,
                                        previous: nil, previousTimestamp: nil, now: now) == nil)
    }

    @Test func normalizedRankingPreservesUnitsAndDoesNotRewardMissingQuality() {
        let a = RouteScore(travelTime: 1_860, distance: 19_000, trafficDelay: nil, maneuverCost: 328,
                           roadQualityCost: nil, reliabilityCost: nil, tollCost: nil)
        let b = RouteScore(travelTime: 1_980, distance: 22_000, trafficDelay: nil, maneuverCost: 64,
                           roadQualityCost: 0, reliabilityCost: 0.8, tollCost: nil)
        let scaled = [a, b].map { RouteScore(travelTime: $0.travelTime * 60, distance: $0.distance / 1_000,
            trafficDelay: nil, maneuverCost: $0.maneuverCost * 10, roadQualityCost: $0.roadQualityCost,
            reliabilityCost: $0.reliabilityCost, tollCost: nil) }
        let first = RouteScoringEngine.rankingValues([a, b], preference: .balanced)
        let second = RouteScoringEngine.rankingValues(scaled, preference: .balanced)
        #expect(first[1] < first[0])
        #expect(zip(first, second).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(RouteScoringEngine.normalized([a, b]).allSatisfy { $0.surface == nil && $0.reliability == nil })
        let unknown = RouteScoringEngine.score(route())
        #expect(!unknown.hasManeuverData)
        #expect(RouteScoringEngine.normalized([a, unknown]).allSatisfy { $0.comfort == nil })
    }

    @Test func destinationRespectsInboundOneWayAndMotorAccessHierarchy() {
        let parking = [Coordinate(latitude: 52.001, longitude: 20.999), Coordinate(latitude: 52.001, longitude: 21.001),
                       Coordinate(latitude: 52.003, longitude: 21.001), Coordinate(latitude: 52.003, longitude: 20.999)]
        let entering = DestinationAccessFeature(id: "in", coordinate: points[0],
            geometry: [points[0], Coordinate(latitude: 52.002, longitude: 21)], tags: ["highway": "service", "oneway": "yes"])
        let exiting = DestinationAccessFeature(id: "out", coordinate: points[0],
            geometry: Array(entering.geometry.reversed()), tags: entering.tags)
        let candidates = DestinationIntelligenceEngine.candidates(parking: parking, features: [entering, exiting])
        #expect(candidates.contains { $0.featureID == "in" && $0.directionVerified })
        #expect(!candidates.contains { $0.featureID == "out" })
        let departures = DestinationIntelligenceEngine.candidates(parking: parking, features: [entering, exiting], purpose: .departure)
        #expect(departures.contains { $0.featureID == "out" })
        #expect(!departures.contains { $0.featureID == "in" })
        let door = DestinationAccessFeature(id: "building-door", coordinate: parking[0], geometry: [], tags: ["entrance": "main"])
        #expect(DestinationIntelligenceEngine.candidates(parking: parking, features: [door]).isEmpty)

        #expect(!DestinationIntelligenceEngine.motorAccessAllowed(["barrier": "bollard"]))
        #expect(DestinationIntelligenceEngine.motorAccessAllowed(["access": "private", "motor_vehicle": "yes"]))
        #expect(!DestinationIntelligenceEngine.motorAccessAllowed(["vehicle": "no"]))
    }

    @Test func lanesUseProviderSelectionAndComplexTurnsPrepareEarlier() {
        let turn = Maneuver(shapeIndex: 1, instruction: "Zjedź", type: 20, lanes: [
            TurnLaneGuidance(id: 0, indications: ["straight"], valid: false),
            TurnLaneGuidance(id: 1, indications: ["right"], valid: true),
            TurnLaneGuidance(id: 2, indications: ["right"], valid: true, active: true)])
        let guidance = LaneGuidanceEngine.guidance(for: turn)
        #expect(guidance?.selectedIndices == [2] && guidance?.providerPreferred == true)
        let easy = GuidanceQualityEngine.evaluate(maneuver: Maneuver(shapeIndex: 0, instruction: "Skręć", type: 10),
                                                  followingDistance: 1_000, speed: 25)
        let complex = GuidanceQualityEngine.evaluate(maneuver: turn, followingDistance: 50, speed: 25)
        #expect(complex.preparationDistance > easy.preparationDistance)
        #expect(complex.laneDistance > easy.laneDistance)
        #expect(complex.stage(at: 10) == 2)
        #expect(complex.stage(at: 5_000) == nil)
    }

    @Test func diagnosticExportReplayAndAllSyntheticBenchmarkCasesAreConsistent() throws {
        let a = route(), b = NavigationRoute(coordinates: points, distance: 2_400, expectedTravelTime: 270, maneuvers: [])
        let record = RoutingDecisionRecord.make(routes: [a, b], preference: .fastest, selected: b.id,
                                                 source: "critical-test", calculationSeconds: 0.25)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decoded = try decoder.decode(RoutingDecisionRecord.self, from: encoder.encode(record))
        #expect(decoded.recommendedRouteID == b.id)
        #expect(RoutingBenchmarkSuite.replay([decoded]).failures == 0)
        #expect(decoded.candidates.allSatisfy { $0.tollDistance == nil && $0.unpavedDistance == nil })
        let report = RoutingBenchmarkSuite.run()
        #expect(report.cases.count == 120)
        #expect(report.failures == 0)
        #expect(report.dataset.contains("syntetycznych"))
    }
}
