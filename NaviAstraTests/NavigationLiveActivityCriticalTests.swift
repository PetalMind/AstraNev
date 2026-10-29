import CoreLocation
import Foundation
import Testing
@testable import NaviAstra

@MainActor struct NavigationLiveActivityCriticalTests {
    @Test func lifecycleStartsInForegroundThrottlesMovementAndResetsOnEnd() {
        var lifecycle = NavigationActivityLifecyclePolicy()
        let backgroundStart = lifecycle.requestStart(isForeground: false, systemAuthorized: true)
        let deniedStart = lifecycle.requestStart(isForeground: true, systemAuthorized: false)
        let foregroundStart = lifecycle.requestStart(isForeground: true, systemAuthorized: true)
        let duplicateStart = lifecycle.requestStart(isForeground: true, systemAuthorized: true)
        #expect(!backgroundStart && !deniedStart && foregroundStart && !duplicateStart)
        var policy = NavigationActivityUpdatePolicy()
        let now = Date()
        #expect(policy.shouldPublish(maneuverKey: "straight", movementBucket: 0, at: now))
        policy.didPublish(maneuverKey: "straight", movementBucket: 0, at: now)
        #expect(!policy.shouldPublish(maneuverKey: "straight", movementBucket: 1, at: now.addingTimeInterval(1)))
        #expect(policy.shouldPublish(maneuverKey: "straight", movementBucket: 1, at: now.addingTimeInterval(5)))
        #expect(!policy.shouldPublish(maneuverKey: "straight", movementBucket: 0, at: now.addingTimeInterval(29)))
        #expect(policy.shouldPublish(maneuverKey: "straight", movementBucket: 0, at: now.addingTimeInterval(30)))
        #expect(policy.shouldPublish(maneuverKey: "rerouting", movementBucket: 0, at: now.addingTimeInterval(1)))
        #expect(policy.shouldPublish(maneuverKey: "GPS lost", movementBucket: 0, at: now.addingTimeInterval(1)))
        let previousGeneration = lifecycle.generation
        lifecycle.end()
        #expect(lifecycle.generation != previousGeneration)
        policy.end()
        let backgroundRestart = lifecycle.requestStart(isForeground: false, systemAuthorized: true)
        let nextNavigation = lifecycle.requestStart(isForeground: true, systemAuthorized: true)
        #expect(!backgroundRestart && nextNavigation)
        #expect(policy.lastPublishedAt == nil)
    }

    @Test func lockingPreservesOnlyActiveNavigationSessionWithoutRequiringAlwaysPermission() {
        let engine = EnergyPolicyEngine()
        for mode in [TransportMode.car, .walking, .bicycle, .transit] {
            let foreground = engine.update(navigationStatus: .navigating, transportMode: mode,
                appIsForeground: true, lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: 10)
            let background = engine.update(navigationStatus: .navigating, transportMode: mode,
                appIsForeground: false, lowPowerMode: true, thermalState: .serious, speedMetersPerSecond: 10)
            #expect(NavigationBackgroundLocationPolicy.preservesContinuousSession(previous: foreground.location, next: background.location))
            #expect(NavigationBackgroundLocationPolicy.allowsDelivery(demandIsContinuous: background.location.demand == .continuous,
                navigationAllowsBackground: background.location.allowsBackgroundUpdates,
                authorization: .authorizedWhenInUse, backgroundModeEnabled: true))
            #expect(background.mapFramesPerSecond == 0 && !background.enables3DBuildings)
            let stopped = engine.update(navigationStatus: .idle, transportMode: mode,
                appIsForeground: false, lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: 0)
            #expect(!NavigationBackgroundLocationPolicy.preservesContinuousSession(previous: background.location, next: stopped.location))
            #expect(!NavigationBackgroundLocationPolicy.allowsDelivery(demandIsContinuous: stopped.location.demand == .continuous,
                navigationAllowsBackground: stopped.location.allowsBackgroundUpdates,
                authorization: .authorizedAlways, backgroundModeEnabled: true))
        }
        for status in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            #expect(!NavigationBackgroundLocationPolicy.allowsDelivery(demandIsContinuous: true,
                navigationAllowsBackground: true, authorization: status, backgroundModeEnabled: true))
        }
        #expect(!NavigationBackgroundLocationPolicy.allowsDelivery(demandIsContinuous: true,
            navigationAllowsBackground: true, authorization: .authorizedWhenInUse, backgroundModeEnabled: false))
    }

    @Test func routeDiagramKeepsBendsWithoutSharingGPSAndPayloadLeavesActivityKitHeadroom() throws {
        let origin = Coordinate(latitude: 52, longitude: 21)
        let turn = Coordinate(latitude: 52.01, longitude: 21)
        let end = Coordinate(latitude: 52.01, longitude: 21.01)
        let maneuver = Maneuver(shapeIndex: 1, instruction: "Skręć w prawo", type: ManeuverKind.right.rawValue)
        let route = NavigationRoute(coordinates: [origin, turn, end], distance: 2_200,
            expectedTravelTime: 300, maneuvers: [maneuver])
        let progress = RouteProgress(traveledDistance: 300, remainingDistance: 1_900,
            remainingTime: 260, distanceToNextManeuver: 800, nextManeuver: maneuver)
        let geometry = RouteProgressGeometry(route)
        let sketch = try #require(NavigationActivitySketchBuilder.make(route: route, progress: progress,
            location: geometry.coordinate(at: 300), course: 0))
        #expect(NavigationActivitySketchBuilder.make(route: route, progress: progress,
            location: Coordinate(latitude: 53, longitude: 22), course: 0) == nil)
        #expect(sketch.points.count <= 36)
        #expect(sketch.maneuver != nil)
        #expect(Set(sketch.points.map(\.x)).count > 3)
        #expect(Set(sketch.points.map(\.y)).count > 3)
        #expect(sketch.points.allSatisfy { (0...1_000).contains($0.x) && (0...1_000).contains($0.y) })
        let state = NavigationActivityAttributes.ContentState(maneuver: 10, symbolName: "arrow.turn.up.right",
            instruction: String(repeating: "ą", count: 100), roadName: String(repeating: "Ż", count: 60),
            maneuverDistance: 800, remainingDistance: nil, remainingTime: nil, arrivalTime: nil,
            routeProgress: 0.15, isRerouting: false, roundabout: nil, gpsSignalLost: false,
            routeSketch: sketch, movementBucket: 7)
        let encoded = try JSONEncoder().encode(state)
        #expect(encoded.count < 3_500)
        #expect(NavigationActivityPayload.isWithinBudget(state))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["remainingDistance"] == nil && json["remainingTime"] == nil)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("latitude") && !text.contains("longitude"))
        #expect(!NavigationActivityPayload.isWithinBudget(String(repeating: "x", count: 4_100)))
    }

    @Test func missingRoutedMetricsNeverBecomeZeroAndTransitConnectorIsNotWalkingGeometry() throws {
        #expect(RoutedTravelMetrics(time: nil, distance: nil) == nil)
        #expect(RoutedTravelMetrics(time: 120, distance: nil) == nil)
        #expect(RoutedTravelMetrics(time: .infinity, distance: 100) == nil)
        #expect(RoutedTravelMetrics(time: 120, distance: -1) == nil)
        #expect(RoutedTravelMetrics(time: 120, distance: 3_400)?.distance == 3_400)
        let leg: [String: Any] = [
            "mode": "WALK", "from": ["name": "Start", "lat": 52, "lon": 21],
            "to": ["name": "Cel", "lat": 52.01, "lon": 21.01], "duration": 300,
            "startTime": "2026-10-27T10:00:00Z", "endTime": "2026-10-27T10:05:00Z",
            "scheduledStartTime": "2026-10-27T10:00:00Z", "scheduledEndTime": "2026-10-27T10:05:00Z",
            "realTime": false, "legGeometry": ["points": "", "precision": 5, "length": 0]
        ]
        func reply(_ value: [String: Any]) throws -> TransitousPlanResponseDTO {
            let itinerary: [String: Any] = ["id": "missing-path", "duration": 300,
                "startTime": "2026-10-27T10:00:00Z", "endTime": "2026-10-27T10:05:00Z",
                "transfers": 0, "legs": [value]]
            return try JSONDecoder().decode(TransitousPlanResponseDTO.self,
                from: JSONSerialization.data(withJSONObject: ["itineraries": [itinerary]]))
        }
        let missing = try reply(leg)
        #expect(throws: TransitRouteError.self) { try TransitousMapper.journeys(from: missing) }
        var provided = leg
        provided["distance"] = 2_750
        let journey = try #require(TransitousMapper.journeys(from: reply(provided)).first)
        #expect(journey.walkingDistance == 2_750)
        #expect(!journey.legs[0].hasResolvedGeometry)
        let mapped = TransitNavigationRouteMapper.route(from: journey)
        #expect(mapped.distance == 2_750)
        #expect(mapped.journey?.legs.first?.hasResolvedWalkingGeometry == false)
        #expect(mapped.journey?.legs.first?.hasResolvedRouteGeometry == false)
        let progress = RouteProgress(traveledDistance: 0, remainingDistance: mapped.distance,
            remainingTime: mapped.expectedTravelTime, distanceToNextManeuver: .infinity, nextManeuver: nil)
        #expect(NavigationActivitySketchBuilder.make(route: mapped, progress: progress,
            location: mapped.coordinates.first, course: 0) == nil)
    }
}
