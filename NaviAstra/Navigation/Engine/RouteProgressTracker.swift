import Foundation

struct RouteProgressMeasurement {
    let projection: RouteProjection
    let matchedRoute: RouteMatch?
    let fraction: Double
    let geometryFraction: Double
    let geometryLength: Double
    let canAdvanceGeometryProgress: Bool
    let nextManeuver: Maneuver?
    let distanceToNextManeuver: Double
}

/// Owns the geometry caches and route-coordinate calculations used by the
/// navigation engine. State publication and navigation side effects remain in
/// `NavigationEngine`.
struct RouteProgressTracker {
    private var roadGeometry: RouteProgressGeometry?
    private var transitGeometry: TransitRouteProgressGeometry?
    private var displayedProgress: (routeID: UUID, fraction: Double)?

    mutating func measureRoadProgress(
        route: NavigationRoute,
        location: NavigationLocation,
        previousMatch: RouteProjection?,
        previousTimestamp: Date?
    ) -> RouteProgressMeasurement? {
        let geometry = roadGeometry(for: route)
        let matchedRoute = geometry.match(
            location,
            previous: previousMatch,
            previousTimestamp: previousTimestamp)
        guard let projection = matchedRoute?.projection
                ?? MapMatcher.project(location.coordinate, onto: route.coordinates) else {
            return nil
        }

        let geometryLength = geometry.length
        let totalGeometry = route.distance > 0 ? route.distance : geometryLength
        let fraction = totalGeometry > 0 ? min(1, projection.alongRoute / totalGeometry) : 0
        let geometryFraction = geometryLength > 0 ? projection.alongRoute / geometryLength : 0
        let canAdvanceGeometryProgress = projection.distanceFromRoute <= max(40, location.accuracy * 1.5)
        let nextManeuver = route.maneuvers.first { $0.shapeIndex >= projection.segment + 1 }
        let distanceToNextManeuver: Double
        if let nextManeuver {
            distanceToNextManeuver = max(
                0,
                geometry.distance(from: projection.segment, through: nextManeuver.shapeIndex)
                    - route.coordinates[projection.segment].distance(to: projection.coordinate))
        } else {
            distanceToNextManeuver = 0
        }

        return RouteProgressMeasurement(
            projection: projection,
            matchedRoute: matchedRoute,
            fraction: fraction,
            geometryFraction: geometryFraction,
            geometryLength: geometryLength,
            canAdvanceGeometryProgress: canAdvanceGeometryProgress,
            nextManeuver: nextManeuver,
            distanceToNextManeuver: distanceToNextManeuver)
    }

    mutating func transitProgress(
        route: NavigationRoute,
        at coordinate: Coordinate,
        accuracy: Double,
        previousLegIndex: Int?
    ) -> TransitNavigationProgress? {
        TransitRouteProgressCalculator.progress(
            route: route,
            geometry: transitGeometry(for: route),
            at: coordinate,
            accuracy: accuracy,
            previousLegIndex: previousLegIndex)
    }

    mutating func displayedGeometryProgress(
        routeID: UUID,
        candidate: Double,
        canAdvance: Bool,
        isNavigationActive: Bool
    ) -> Double {
        guard isNavigationActive else {
            displayedProgress = nil
            return 0
        }

        let previous = displayedProgress?.routeID == routeID
            ? displayedProgress?.fraction ?? 0
            : 0
        let snapped = candidate.isFinite ? max(0, min(1, candidate)) : previous
        let displayed = canAdvance ? max(previous, snapped) : previous
        displayedProgress = (routeID, displayed)
        return displayed
    }

    mutating func resetDisplayedGeometryProgress() {
        displayedProgress = nil
    }

    mutating func invalidateRoadGeometry() {
        roadGeometry = nil
    }

    mutating func invalidateTransitGeometry() {
        transitGeometry = nil
    }

    mutating func invalidateGeometries() {
        invalidateRoadGeometry()
        invalidateTransitGeometry()
    }

    private mutating func roadGeometry(for route: NavigationRoute) -> RouteProgressGeometry {
        if let roadGeometry, roadGeometry.routeID == Optional(route.id) {
            return roadGeometry
        }
        let geometry = RouteProgressGeometry(route)
        roadGeometry = geometry
        return geometry
    }

    private mutating func transitGeometry(for route: NavigationRoute) -> TransitRouteProgressGeometry {
        if let transitGeometry, transitGeometry.routeID == route.id {
            return transitGeometry
        }
        let geometry = TransitRouteProgressGeometry(route: route)
        transitGeometry = geometry
        return geometry
    }
}
