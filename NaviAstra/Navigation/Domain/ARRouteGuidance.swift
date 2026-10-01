import Foundation
import CoreLocation

nonisolated struct ARArrowPoint: Equatable, Sendable {
    let coordinate: Coordinate
    let bearing: Double
}

/// Shared by launch readiness and both renderers. Progress is a fraction of
/// geometry length, never a fraction of the number of vertices.
nonisolated enum ARRouteGuidance {
    static func hasUsableLocation(_ location: NavigationLocation?, at now: Date = .now) -> Bool {
        guard let location else { return false }
        let age = now.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate.cl)
            && location.accuracy.isFinite && (0...25).contains(location.accuracy)
            && age.isFinite && (0...15).contains(age)
    }

    static func points(geometry: RouteProgressGeometry, progress: RouteProgress?,
                       location: NavigationLocation?, at now: Date = .now) -> [ARArrowPoint] {
        guard hasUsableLocation(location, at: now), let location,
              geometry.length.isFinite, geometry.length > 0,
              let projection = geometry.project(location.coordinate),
              projection.distanceFromRoute <= max(15, location.accuracy) else { return [] }
        let along: Double
        if let progress, progress.geometryRouteID == geometry.routeID,
           progress.geometryProgress.isFinite {
            along = min(1, max(0, progress.geometryProgress)) * geometry.length
        } else {
            along = projection.alongRoute
        }
        // A fixed metre grid keeps anchors stable as GPS/progress changes.
        let first = ceil((along + 4) / 4) * 4
        let end = min(geometry.length, along + 48)
        guard first <= end else { return [] }
        return stride(from: first, through: end, by: 4).compactMap { distance in
            guard let coordinate = geometry.coordinate(at: distance),
                  location.coordinate.distance(to: coordinate) >= 3,
                  location.coordinate.distance(to: coordinate) <= 120,
                  let before = geometry.coordinate(at: max(0, distance - 1)),
                  let after = geometry.coordinate(at: min(geometry.length, distance + 1)),
                  before.distance(to: after) > 0.1 else { return nil }
            return ARArrowPoint(coordinate: coordinate, bearing: bearing(from: before, to: after))
        }
    }

    static func bearing(from start: Coordinate, to end: Coordinate) -> Double {
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// ARKit's heading-aligned axes are east (+X), up (+Y), south (+Z).
    static func offset(from origin: Coordinate, to coordinate: Coordinate) -> SIMD3<Float> {
        let distance = origin.distance(to: coordinate)
        let radians = bearing(from: origin, to: coordinate) * .pi / 180
        return SIMD3(Float(distance * sin(radians)), 0, Float(-distance * cos(radians)))
    }

    static func yaw(for bearing: Double) -> Float { Float(-bearing * .pi / 180) }
}
