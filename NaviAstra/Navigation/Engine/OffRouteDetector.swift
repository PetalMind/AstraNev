import Foundation

/// Tracks consecutive, distinct location fixes that provide enough evidence
/// that the user has left the active road route.
struct OffRouteDetector {
    private var departureSince: Date?
    private var sampleCount = 0
    private var lastSampleTimestamp: Date?

    mutating func shouldRequestReroute(
        location: NavigationLocation,
        route: NavigationRoute,
        projection: RouteProjection,
        matchConfidence: Double
    ) -> Bool {
        let hasReliablePosition = location.accuracy <= 45
        let isFarFromRoute = projection.distanceFromRoute > max(40, location.accuracy * 1.5)
        let hasWeakRouteMatch = matchConfidence < 0.25
        let hasInconsistentCourse = Self.courseDiffersFromRoute(
            location,
            route: route,
            projection: projection)
        let sustainedDeparture = hasReliablePosition && isFarFromRoute && hasWeakRouteMatch &&
            (hasInconsistentCourse || matchConfidence < 0.1)

        guard sustainedDeparture else {
            reset()
            return false
        }

        if lastSampleTimestamp != location.timestamp {
            sampleCount += 1
            lastSampleTimestamp = location.timestamp
        }

        guard let departureSince else {
            self.departureSince = location.timestamp
            return false
        }

        return sampleCount >= 3 && location.timestamp.timeIntervalSince(departureSince) >= 2
    }

    mutating func reset() {
        departureSince = nil
        sampleCount = 0
        lastSampleTimestamp = nil
    }

    private static func courseDiffersFromRoute(
        _ location: NavigationLocation,
        route: NavigationRoute,
        projection: RouteProjection
    ) -> Bool {
        guard location.speed >= 2.5,
              location.course.isFinite,
              (0...360).contains(location.course),
              location.courseAccuracy < 0 || location.courseAccuracy <= 45,
              route.coordinates.indices.contains(projection.segment),
              route.coordinates.indices.contains(projection.segment + 1) else { return false }

        let start = route.coordinates[projection.segment]
        let end = route.coordinates[projection.segment + 1]
        let dx = (end.longitude - start.longitude) * 111_320.0 *
            cos(location.coordinate.latitude * .pi / 180)
        let dy = (end.latitude - start.latitude) * 110_574.0
        let routeCourse = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let difference = abs(location.course - routeCourse)
        return min(difference, 360 - difference) >= 55
    }
}
