//
//  NaviAstraTests.swift
//  NaviAstraTests
//
//  Created by Dominik on 23/09/2026.
//

import Testing
@testable import NaviAstra

struct NaviAstraTests {

    @Test @MainActor func energyPolicySeparatesBrowsingPreviewAndBackgroundModes() {
        let policyEngine = EnergyPolicyEngine()

        let browsing = policyEngine.update(
            navigationStatus: .idle, transportMode: .car, appIsForeground: true,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: nil)
        #expect(browsing.mode == .mapBrowsing)
        #expect(browsing.location.demand == .continuous)
        #expect(browsing.location.accuracy == .hundredMeters)
        #expect(browsing.location.distanceFilter == 50)
        #expect(browsing.trafficRefreshInterval == nil)

        let preview = policyEngine.update(
            navigationStatus: .routePreview, transportMode: .car, appIsForeground: true,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: nil)
        #expect(preview.mode == .routePreview)
        #expect(preview.location.demand == .oneShot)
        #expect(preview.location.accuracy == .bestForNavigation)
        #expect(preview.trafficRefreshInterval == 90)

        let background = policyEngine.update(
            navigationStatus: .navigating, transportMode: .car, appIsForeground: false,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: 20)
        #expect(background.mode == .backgroundNavigation)
        #expect(background.location.demand == .continuous)
        #expect(background.location.allowsBackgroundUpdates)
        #expect(background.location.distanceFilter == 8)
        #expect(background.mapFramesPerSecond == 0)
        #expect(background.trafficRefreshInterval == 60)

        let idleBackground = policyEngine.update(
            navigationStatus: .idle, transportMode: .car, appIsForeground: false,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: nil)
        #expect(idleBackground.mode == .idle)
        #expect(idleBackground.location.demand == .stopped)
        #expect(idleBackground.mapFramesPerSecond == 0)
        #expect(idleBackground.trafficRefreshInterval == nil)
    }

    @Test @MainActor func energyPolicyReducesRenderingWithoutReducingActiveNavigationAccuracy() {
        let policyEngine = EnergyPolicyEngine()
        let normal = policyEngine.update(
            navigationStatus: .navigating, transportMode: .car, appIsForeground: true,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: 28)
        let lowPower = policyEngine.update(
            navigationStatus: .navigating, transportMode: .car, appIsForeground: true,
            lowPowerMode: true, thermalState: .nominal, speedMetersPerSecond: 28)
        let thermal = policyEngine.update(
            navigationStatus: .navigating, transportMode: .car, appIsForeground: true,
            lowPowerMode: false, thermalState: .serious, speedMetersPerSecond: 28)

        #expect(normal.location == lowPower.location)
        #expect(normal.location == thermal.location)
        #expect(normal.location.accuracy == .bestForNavigation)
        #expect(normal.location.distanceFilter == 3)
        #expect(normal.mapFramesPerSecond == 60)
        #expect(lowPower.mapFramesPerSecond == 30)
        #expect(thermal.mapFramesPerSecond == 30)
        #expect(lowPower.trafficRefreshInterval == 60)
        #expect(thermal.trafficRefreshInterval == 60)
        #expect(!lowPower.enables3DBuildings)
        #expect(!thermal.enablesMapPrefetch)

        let walking = policyEngine.update(
            navigationStatus: .navigating, transportMode: .walking, appIsForeground: true,
            lowPowerMode: false, thermalState: .nominal, speedMetersPerSecond: 1.2)
        #expect(walking.mode == .walking)
        #expect(walking.location.accuracy == .nearestTenMeters)
        #expect(walking.location.distanceFilter == 5)
        #expect(walking.location.updatesHeading)
        #expect(walking.mapFramesPerSecond == 60)
    }

    @Test func speedLimitParserNormalizesUnitsAndRejectsUnresolvedValues() {
        #expect(SpeedLimitParser.parse("50 km/h") == 50)
        #expect(SpeedLimitParser.parse("50 mph") == 80)
        #expect(SpeedLimitParser.parse("PL:urban") == 50)
        #expect(SpeedLimitParser.parse("signals") == nil)
    }

    @Test func PolishLegalDefaultsUseMappedRoadClassAndLaneContext() {
        #expect(SpeedLimitParser.parse(nil, tags: ["source:maxspeed": "PL:urban"]) == 50)
        #expect(SpeedLimitParser.parse(nil, tags: ["source:maxspeed": "PL:rural",
                                                     "highway": "primary", "dual_carriageway": "yes",
                                                     "lanes": "4"]) == 100)
        #expect(SpeedLimitParser.parse(nil, tags: ["source:maxspeed": "PL:expressway",
                                                     "dual_carriageway": "yes"]) == 120)
        #expect(SpeedLimitParser.parse(nil, tags: ["source:maxspeed": "PL:expressway",
                                                     "dual_carriageway": "no"]) == 100)
        #expect(SpeedLimitParser.parse(nil, tags: ["source:maxspeed": "PL:rural",
                                                     "highway": "primary", "lanes": "4"]) == nil)
    }

    @Test func conditionalSpeedLimitAppliesWeekdayAndTimeWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 21 // Monday
        components.hour = 8
        let activeDate = try #require(calendar.date(from: components))
        let inactiveDate = try #require(calendar.date(byAdding: .hour, value: 15, to: activeDate))
        let segment = OSMRoadSpeedSegment(id: 1,
                                          coordinates: [Coordinate(latitude: 52, longitude: 21),
                                                        Coordinate(latitude: 52.001, longitude: 21)],
                                          tags: ["maxspeed": "50",
                                                 "maxspeed:conditional": "30 @ (Mo-Fr 06:00-22:00)"])
        let projection = RouteProjection(coordinate: Coordinate(latitude: 52, longitude: 21),
                                         distanceFromRoute: 0, alongRoute: 0, segment: 0)

        #expect(ConditionalSpeedLimitResolver.speedLimit(tags: segment.tags, heading: 0,
                                                         segment: segment, projection: projection,
                                                         date: activeDate, timeZone: timeZone) == 30)
        #expect(ConditionalSpeedLimitResolver.speedLimit(tags: segment.tags, heading: 0,
                                                         segment: segment, projection: projection,
                                                         date: inactiveDate, timeZone: timeZone) == 50)
    }

    @Test func directionalSpeedLimitNeedsAUsableHeading() {
        let segment = OSMRoadSpeedSegment(id: 2,
                                          coordinates: [Coordinate(latitude: 52, longitude: 21),
                                                        Coordinate(latitude: 52.001, longitude: 21)],
                                          tags: ["maxspeed:forward": "50", "maxspeed:backward": "80"])
        let projection = RouteProjection(coordinate: Coordinate(latitude: 52, longitude: 21),
                                         distanceFromRoute: 0, alongRoute: 0, segment: 0)
        let timeZone = TimeZone(secondsFromGMT: 0)!

        #expect(ConditionalSpeedLimitResolver.speedLimit(tags: segment.tags, heading: -1,
                                                         segment: segment, projection: projection,
                                                         date: .now, timeZone: timeZone) == nil)
        #expect(ConditionalSpeedLimitResolver.speedLimit(tags: segment.tags, heading: 0,
                                                         segment: segment, projection: projection,
                                                         date: .now, timeZone: timeZone) == 50)
        #expect(ConditionalSpeedLimitResolver.speedLimit(tags: segment.tags, heading: 180,
                                                         segment: segment, projection: projection,
                                                         date: .now, timeZone: timeZone) == 80)
    }

    @Test @MainActor func transitProgressFindsUpcomingStopsFromGPSPosition() {
        let route = sampleTransitRoute()
        let progress = TransitRouteProgressCalculator.progress(
            route: route,
            at: Coordinate(latitude: 0, longitude: 0.002),
            accuracy: 5)

        #expect(progress?.nextStop?.stopID == "stop-2")
        #expect(progress?.stopsUntilAlighting == 3)
        #expect((progress?.routeFraction ?? 0) > 0.1)
    }

    @Test @MainActor func transitProgressKeepsAlightingStopAsNextNearArrival() {
        let route = sampleTransitRoute()
        let progress = TransitRouteProgressCalculator.progress(
            route: route,
            at: Coordinate(latitude: 0, longitude: 0.0095),
            accuracy: 5)

        #expect(progress?.nextStop?.stopID == "stop-4")
        #expect(progress?.stopsUntilAlighting == 1)
    }

    @Test @MainActor func transitProgressDoesNotClaimTrackingFarFromJourney() {
        let route = sampleTransitRoute()
        let progress = TransitRouteProgressCalculator.progress(
            route: route,
            at: Coordinate(latitude: 0.05, longitude: 0.05),
            accuracy: 5)

        #expect(progress == nil)
    }

    @Test @MainActor func routeProgressTrackerKeepsDisplayedProgressMonotonic() {
        var tracker = RouteProgressTracker()
        let routeID = UUID()

        #expect(tracker.displayedGeometryProgress(routeID: routeID, candidate: 0.6,
                                                  canAdvance: true,
                                                  isNavigationActive: true) == 0.6)
        #expect(tracker.displayedGeometryProgress(routeID: routeID, candidate: 0.25,
                                                  canAdvance: true,
                                                  isNavigationActive: true) == 0.6)
        #expect(tracker.displayedGeometryProgress(routeID: routeID, candidate: 0.9,
                                                  canAdvance: false,
                                                  isNavigationActive: true) == 0.6)
        #expect(tracker.displayedGeometryProgress(routeID: UUID(), candidate: 0.2,
                                                  canAdvance: true,
                                                  isNavigationActive: true) == 0.2)
    }

    @Test @MainActor func routeProgressTrackerUsesAccuracyThresholdForGeometryAdvance() {
        var tracker = RouteProgressTracker()
        let route = route(from: Coordinate(latitude: 0, longitude: 0),
                          to: Coordinate(latitude: 0, longitude: 0.02),
                          expectedTravelTime: 1_000)
        let timestamp = Date()
        let withinThreshold = NavigationLocation(
            coordinate: Coordinate(latitude: 0.0003, longitude: 0.005),
            speed: 0, course: -1, accuracy: 10, timestamp: timestamp)
        let outsideThreshold = NavigationLocation(
            coordinate: Coordinate(latitude: 0.0004, longitude: 0.005),
            speed: 0, course: -1, accuracy: 10, timestamp: timestamp)
        let scaledThreshold = NavigationLocation(
            coordinate: Coordinate(latitude: 0.0008, longitude: 0.005),
            speed: 0, course: -1, accuracy: 60, timestamp: timestamp)
        let outsideScaledThreshold = NavigationLocation(
            coordinate: Coordinate(latitude: 0.00083, longitude: 0.005),
            speed: 0, course: -1, accuracy: 60, timestamp: timestamp)

        let accepted = tracker.measureRoadProgress(route: route, location: withinThreshold,
                                                   previousMatch: nil, previousTimestamp: nil)
        let held = tracker.measureRoadProgress(route: route, location: outsideThreshold,
                                               previousMatch: nil, previousTimestamp: nil)
        let acceptedWithScaledAccuracy = tracker.measureRoadProgress(
            route: route, location: scaledThreshold, previousMatch: nil, previousTimestamp: nil)
        let heldWithScaledAccuracy = tracker.measureRoadProgress(
            route: route, location: outsideScaledThreshold,
            previousMatch: nil, previousTimestamp: nil)

        #expect((accepted?.projection.distanceFromRoute ?? .infinity) <= 40)
        #expect(accepted?.canAdvanceGeometryProgress == true)
        #expect((held?.projection.distanceFromRoute ?? 0) > 40)
        #expect(held?.canAdvanceGeometryProgress == false)
        #expect((acceptedWithScaledAccuracy?.projection.distanceFromRoute ?? .infinity) <= 90)
        #expect(acceptedWithScaledAccuracy?.canAdvanceGeometryProgress == true)
        #expect((heldWithScaledAccuracy?.projection.distanceFromRoute ?? 0) > 90)
        #expect(heldWithScaledAccuracy?.canAdvanceGeometryProgress == false)
    }

    @Test @MainActor func routeProgressTrackerMeasuresDistanceToNextManeuver() {
        var tracker = RouteProgressTracker()
        let coordinates = (0...3).map { index in
            Coordinate(latitude: 0, longitude: Double(index) * 0.001)
        }
        let distance = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let route = NavigationRoute(
            coordinates: coordinates,
            distance: distance,
            expectedTravelTime: 300,
            maneuvers: [Maneuver(shapeIndex: 3, instruction: "Skręć w prawo",
                                 type: ManeuverKind.right.rawValue)])
        let location = NavigationLocation(
            coordinate: Coordinate(latitude: 0, longitude: 0.0015),
            speed: 0, course: -1, accuracy: 5, timestamp: Date())

        let measurement = tracker.measureRoadProgress(route: route, location: location,
                                                     previousMatch: nil, previousTimestamp: nil)
        let expectedDistance = Coordinate(latitude: 0, longitude: 0.0015)
            .distance(to: coordinates[3])

        #expect(measurement?.nextManeuver?.shapeIndex == 3)
        #expect(abs((measurement?.distanceToNextManeuver ?? .infinity) - expectedDistance) < 1)
    }

    @Test @MainActor func routeProgressTrackerInvalidationRebuildsRouteCacheAndResetsProgress() {
        var tracker = RouteProgressTracker()
        var route = self.route(from: Coordinate(latitude: 0, longitude: 0),
                               to: Coordinate(latitude: 0, longitude: 0.004),
                               expectedTravelTime: 600)
        let location = NavigationLocation(
            coordinate: Coordinate(latitude: 0, longitude: 0.001),
            speed: 0, course: -1, accuracy: 5, timestamp: Date())
        let initial = tracker.measureRoadProgress(route: route, location: location,
                                                  previousMatch: nil, previousTimestamp: nil)
        let initialLength = initial?.geometryLength ?? 0

        #expect(tracker.displayedGeometryProgress(routeID: route.id, candidate: 0.7,
                                                  canAdvance: true,
                                                  isNavigationActive: true) == 0.7)

        route.coordinates = [Coordinate(latitude: 0, longitude: 0),
                             Coordinate(latitude: 0, longitude: 0.008)]
        route.distance = route.coordinates[0].distance(to: route.coordinates[1])
        let cached = tracker.measureRoadProgress(route: route, location: location,
                                                 previousMatch: nil, previousTimestamp: nil)
        tracker.invalidateRoadGeometry()
        tracker.resetDisplayedGeometryProgress()
        let rebuilt = tracker.measureRoadProgress(route: route, location: location,
                                                  previousMatch: nil, previousTimestamp: nil)

        #expect(abs((cached?.geometryLength ?? 0) - initialLength) < 1)
        #expect((rebuilt?.geometryLength ?? 0) > initialLength * 1.9)
        #expect(tracker.displayedGeometryProgress(routeID: route.id, candidate: 0.2,
                                                  canAdvance: true,
                                                  isNavigationActive: true) == 0.2)
    }

    @Test @MainActor func offRouteDetectorRequiresThreeDistinctFixesAcrossTwoSeconds() {
        var detector = OffRouteDetector()
        let route = self.route(from: Coordinate(latitude: 0, longitude: 0),
                               to: Coordinate(latitude: 0, longitude: 0.01),
                               expectedTravelTime: 600)
        let projection = RouteProjection(coordinate: Coordinate(latitude: 0, longitude: 0.005),
                                         distanceFromRoute: 100, alongRoute: 500, segment: 0)
        let start = Date(timeIntervalSince1970: 1_000)
        func location(at offset: TimeInterval) -> NavigationLocation {
            NavigationLocation(coordinate: Coordinate(latitude: 0.001, longitude: 0.005),
                               speed: 10, course: 180, accuracy: 5,
                               timestamp: start.addingTimeInterval(offset), courseAccuracy: 5)
        }

        #expect(!detector.shouldRequestReroute(location: location(at: 0), route: route,
                                               projection: projection, matchConfidence: 0.2))
        #expect(!detector.shouldRequestReroute(location: location(at: 0), route: route,
                                               projection: projection, matchConfidence: 0.2))
        #expect(!detector.shouldRequestReroute(location: location(at: 1), route: route,
                                               projection: projection, matchConfidence: 0.2))
        #expect(detector.shouldRequestReroute(location: location(at: 2), route: route,
                                              projection: projection, matchConfidence: 0.2))
    }

    @Test @MainActor func offRouteDetectorResetsWhenPositionOrHeadingEvidenceIsNoLongerValid() {
        var detector = OffRouteDetector()
        let route = self.route(from: Coordinate(latitude: 0, longitude: 0),
                               to: Coordinate(latitude: 0, longitude: 0.01),
                               expectedTravelTime: 600)
        let projection = RouteProjection(coordinate: Coordinate(latitude: 0, longitude: 0.005),
                                         distanceFromRoute: 100, alongRoute: 500, segment: 0)
        let start = Date(timeIntervalSince1970: 2_000)
        func location(at offset: TimeInterval, latitude: Double = 0.001,
                      course: Double = 180) -> NavigationLocation {
            NavigationLocation(coordinate: Coordinate(latitude: latitude, longitude: 0.005),
                               speed: 10, course: course, accuracy: 5,
                               timestamp: start.addingTimeInterval(offset), courseAccuracy: 5)
        }

        #expect(!detector.shouldRequestReroute(location: location(at: 0), route: route,
                                               projection: projection, matchConfidence: 0.2))
        let nearbyProjection = RouteProjection(coordinate: Coordinate(latitude: 0, longitude: 0.005),
                                               distanceFromRoute: 0, alongRoute: 500, segment: 0)
        #expect(!detector.shouldRequestReroute(location: location(at: 1, latitude: 0), route: route,
                                               projection: nearbyProjection, matchConfidence: 0.8))
        #expect(!detector.shouldRequestReroute(location: location(at: 3), route: route,
                                               projection: projection, matchConfidence: 0.2))
        #expect(!detector.shouldRequestReroute(location: location(at: 4, course: 90), route: route,
                                               projection: projection, matchConfidence: 0.2))
        #expect(!detector.shouldRequestReroute(location: location(at: 5), route: route,
                                               projection: projection, matchConfidence: 0.2))
    }

    @Test @MainActor func routeTrafficLookAheadUsesTravelTimeAndRoadSpeed() {
        let cityRoute = route(from: Coordinate(latitude: 0, longitude: 0),
                              to: Coordinate(latitude: 0, longitude: 0.8),
                              expectedTravelTime: 10_800)
        let highwayRoute = route(from: Coordinate(latitude: 0, longitude: 0),
                                 to: Coordinate(latitude: 0, longitude: 0.8),
                                 expectedTravelTime: 3_200)

        let cityDistance = RouteTrafficMonitor.lookAheadDistance(for: cityRoute, progress: nil)
        let highwayDistance = RouteTrafficMonitor.lookAheadDistance(for: highwayRoute, progress: nil)

        #expect(abs(cityDistance - cityRoute.distance * 1_500 / 10_800) < 1)
        #expect(abs(highwayDistance - highwayRoute.distance * 1_500 / 3_200) < 1)
        #expect(highwayDistance > cityDistance)
    }

    @Test @MainActor func routeTrafficCorridorSplitsQueriesAndFiltersIncidentsByRoutePosition() {
        let route = route(from: Coordinate(latitude: 0, longitude: 0),
                          to: Coordinate(latitude: 0, longitude: 0.5),
                          expectedTravelTime: 2_000)
        let boxes = RouteTrafficMonitor.queryBoxes(for: route, from: 2_000, through: 42_000)
        let matchedIncident = TrafficIncident(
            id: "road-closure",
            description: "Droga zamknięta",
            coordinate: Coordinate(latitude: 0.01, longitude: 0.2),
            delaySeconds: nil,
            category: .roadClosed,
            severity: .indefinite,
            geometry: [Coordinate(latitude: 0.01, longitude: 0.2),
                       Coordinate(latitude: 0.0003, longitude: 0.2)])
        let outsideCorridor = TrafficIncident(
            id: "nearby-road",
            description: "Korek",
            coordinate: Coordinate(latitude: 0.002, longitude: 0.3),
            delaySeconds: 120,
            category: .jam,
            severity: .moderate)

        let matched = RouteTrafficMonitor.matching([matchedIncident, outsideCorridor], to: route,
                                                   from: 2_000, through: 42_000)

        #expect(boxes.count >= 5)
        #expect(matched.map(\.id) == ["road-closure"])
        #expect((matched.first?.distanceAlongRoute ?? 0) > 20_000)
        #expect((matched.first?.distanceAlongRoute ?? .infinity) < 25_000)
    }

    @MainActor private func sampleTransitRoute() -> NavigationRoute {
        let now = Date()
        let coordinates = (0...10).map { index in
            Coordinate(latitude: 0, longitude: Double(index) * 0.001)
        }
        let stops = [0, 3, 6, 10].enumerated().map { offset, point in
            TransitJourneyStop(id: "stop-\(offset + 1)", stopID: "stop-\(offset + 1)",
                               name: "Przystanek \(offset + 1)", coordinate: coordinates[point],
                               arrival: now.addingTimeInterval(Double(point) * 60),
                               departure: now.addingTimeInterval(Double(point) * 60),
                               delaySeconds: nil, hasRealtime: false, sequence: offset + 1)
        }
        let leg = JourneyLeg(mode: "BUS", line: "15", from: "Początek", to: "Koniec",
                             departure: now, arrival: now.addingTimeInterval(600), realTime: false,
                             coordinates: coordinates, routeID: "route-15", tripID: "trip-15",
                             serviceDate: "20260924", transitStops: stops)
        let journey = Journey(departure: now, arrival: now.addingTimeInterval(600), legs: [leg])
        let distance = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return NavigationRoute(coordinates: coordinates, distance: distance,
                               expectedTravelTime: 600, maneuvers: [], journey: journey)
    }

    @MainActor private func route(from origin: Coordinate, to destination: Coordinate,
                                  expectedTravelTime: TimeInterval) -> NavigationRoute {
        let coordinates = [origin, destination]
        return NavigationRoute(coordinates: coordinates,
                               distance: origin.distance(to: destination),
                               expectedTravelTime: expectedTravelTime,
                               maneuvers: [])
    }
}
