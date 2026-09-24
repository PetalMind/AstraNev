//
//  NaviAstraTests.swift
//  NaviAstraTests
//
//  Created by Dominik on 23/09/2026.
//

import Testing
@testable import NaviAstra

struct NaviAstraTests {

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
}
