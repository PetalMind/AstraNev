import Foundation
import Testing
import simd
@testable import NaviAstra

/// Navigation-critical regressions: route position, direction and invalid fixes.
struct ARRouteGuidanceTests {
    @Test func guidanceUsesMetresRatherThanVertexDensity() throws {
        let start = Coordinate(latitude: 52, longitude: 21)
        let middle = Coordinate(latitude: 52.00005, longitude: 21)
        let end = Coordinate(latitude: 52.002, longitude: 21)
        let id = UUID()
        let sparse = NavigationRoute(id: id, coordinates: [start, middle, end],
                                     distance: start.distance(to: end), expectedTravelTime: 180, maneuvers: [])
        let dense = NavigationRoute(id: id, coordinates: (0...40).map {
            Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * Double($0) / 40,
                       longitude: start.longitude)
        }, distance: sparse.distance, expectedTravelTime: 180, maneuvers: [])
        let geometry = RouteProgressGeometry(sparse)
        let coordinate = try #require(geometry.coordinate(at: geometry.length / 2))
        let now = Date()
        let location = NavigationLocation(coordinate: coordinate, speed: 1, course: 0,
                                          accuracy: 5, timestamp: now)
        let progress = RouteProgress(traveledDistance: sparse.distance / 2,
                                     remainingDistance: sparse.distance / 2, remainingTime: 90,
                                     distanceToNextManeuver: 100, nextManeuver: nil,
                                     geometryProgress: 0.5, geometryRouteID: id)
        let a = ARRouteGuidance.points(geometry: geometry, progress: progress, location: location, at: now)
        let b = ARRouteGuidance.points(geometry: RouteProgressGeometry(dense), progress: progress,
                                      location: location, at: now)
        #expect(!a.isEmpty)
        #expect(a.count == b.count)
        for (pointA, pointB) in zip(a, b) {
            #expect(pointA.coordinate.latitude > coordinate.latitude)
            #expect(pointA.coordinate.distance(to: pointB.coordinate) < 0.1)
        }
        for (first, second) in zip(a, a.dropFirst()) {
            #expect(abs(first.coordinate.distance(to: second.coordinate) - 4) < 0.1)
        }
        // Progress from a previous route must not push guidance to its destination.
        var previousProgress = progress
        previousProgress.geometryRouteID = UUID()
        previousProgress.geometryProgress = 1
        let fallback = ARRouteGuidance.points(geometry: geometry, progress: previousProgress,
                                             location: location, at: now)
        #expect(!fallback.isEmpty)
        #expect(fallback.first?.coordinate == a.first?.coordinate)
    }

    @Test func guidanceRejectsStaleInaccurateAndOffRoutePositions() {
        let now = Date()
        let start = Coordinate(latitude: 52, longitude: 21)
        let route = NavigationRoute(coordinates: [start, Coordinate(latitude: 52.002, longitude: 21)],
                                    distance: 222, expectedTravelTime: 180, maneuvers: [])
        let geometry = RouteProgressGeometry(route)
        let good = NavigationLocation(coordinate: start, speed: 1, course: 0, accuracy: 5, timestamp: now)
        #expect(!ARRouteGuidance.points(geometry: geometry, progress: nil, location: good, at: now).isEmpty)
        var invalidFixes: [NavigationLocation] = []
        for accuracy in [-1.0, 26, .infinity, .nan] {
            var fix = good
            fix.accuracy = accuracy
            invalidFixes.append(fix)
        }
        for age in [-1.0, 16] {
            var fix = good
            fix.timestamp = now.addingTimeInterval(-age)
            invalidFixes.append(fix)
        }
        var offRoute = good
        offRoute.coordinate.longitude += 0.002
        invalidFixes.append(offRoute)
        for fix in invalidFixes {
            #expect(ARRouteGuidance.points(geometry: geometry, progress: nil, location: fix, at: now).isEmpty)
        }
    }

    @Test func arrowRotationAndLocalCoordinatesAgreeInEveryCardinalDirection() {
        let origin = Coordinate(latitude: 52, longitude: 21)
        let destinations: [(Coordinate, SIMD3<Float>)] = [
            (Coordinate(latitude: 52.001, longitude: 21), [0, 0, -1]),
            (Coordinate(latitude: 52, longitude: 21.001), [1, 0, 0]),
            (Coordinate(latitude: 51.999, longitude: 21), [0, 0, 1]),
            (Coordinate(latitude: 52, longitude: 20.999), [-1, 0, 0])
        ]
        for (destination, expected) in destinations {
            let bearing = ARRouteGuidance.bearing(from: origin, to: destination)
            let rotated = simd_quatf(angle: ARRouteGuidance.yaw(for: bearing), axis: [0, 1, 0]).act([0, 0, -1])
            let offset = simd_normalize(ARRouteGuidance.offset(from: origin, to: destination))
            #expect(simd_distance(rotated, expected) < 0.001)
            #expect(simd_distance(offset, expected) < 0.001)
        }
    }
}
