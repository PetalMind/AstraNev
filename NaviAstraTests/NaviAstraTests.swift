//
//  NaviAstraTests.swift
//  NaviAstraTests
//
//  Created by Dominik on 23/09/2026.
//

import Testing
@testable import NaviAstra

struct NaviAstraTests {

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
