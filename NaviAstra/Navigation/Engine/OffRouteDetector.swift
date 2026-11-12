import Foundation

/// Tracks consecutive, distinct location fixes that provide enough evidence
/// that the user has left the active road route.
struct OffRouteDetector {
    private(set) var deviationState: RouteDeviationState = .onRoute
    private var departureSince: Date?
    private var sampleCount = 0
    private var lastSampleTimestamp: Date?
    private var departurePosition: Double?
    private var departureCoordinate: Coordinate?
    private var observedRouteID: UUID?
    private var detectsReverseTravel = false

    mutating func shouldRequestReroute(
        location: NavigationLocation,
        route: NavigationRoute,
        projection: RouteProjection,
        matchConfidence: Double
    ) -> Bool {
        if observedRouteID != route.id { reset() }
        if let previous = lastSampleTimestamp {
            let interval = location.timestamp.timeIntervalSince(previous)
            guard interval > 0 else { return false }
            // A fix after a GPS outage starts a new sequence of evidence.
            if interval > 10 { reset() }
        }
        let hasReliablePosition = location.accuracy.isFinite && (0...45).contains(location.accuracy)
        let isFarFromRoute = projection.distanceFromRoute > max(40, location.accuracy * 1.5)
        let hasWeakRouteMatch = matchConfidence < 0.25
        let courseDifference = Self.courseDifferenceFromRoute(
            location,
            route: route,
            projection: projection)
        let hasInconsistentCourse = (courseDifference ?? 0) >= 55
        let sustainedDeparture = hasReliablePosition && isFarFromRoute && hasWeakRouteMatch &&
            (hasInconsistentCourse || matchConfidence < 0.1)
        // A neighboring ramp can stay inside 40 m for several seconds. Only
        // trust a smaller separation with precise fixes and measured movement.
        let nearbyDeparture = hasReliablePosition && location.accuracy <= 10 && location.speed >= 3 &&
            projection.distanceFromRoute > max(25, location.accuracy * 3) && matchConfidence < 0.1
        let reverseTravel = hasReliablePosition && location.accuracy <= 20 && location.speed >= 3 &&
            location.courseAccuracy >= 0 && location.courseAccuracy <= 25 &&
            !isFarFromRoute && hasWeakRouteMatch && (courseDifference ?? 0) >= 120

        guard sustainedDeparture || nearbyDeparture || reverseTravel else {
            reset()
            return false
        }
        if departureSince != nil, detectsReverseTravel != reverseTravel { reset() }
        detectsReverseTravel = reverseTravel
        observedRouteID = route.id
        sampleCount += 1
        lastSampleTimestamp = location.timestamp

        deviationState = sampleCount >= 2 ? .probablyOffRoute : .suspicious
        guard let departureSince else {
            self.departureSince = location.timestamp
            departurePosition = projection.alongRoute
            departureCoordinate = location.coordinate
            return false
        }

        let confirmed: Bool
        if reverseTravel {
            confirmed = sampleCount >= 4 && location.timestamp.timeIntervalSince(departureSince) >= 5 &&
                (departurePosition ?? projection.alongRoute) - projection.alongRoute >= 15
        } else if sustainedDeparture {
            confirmed = sampleCount >= 3 && location.timestamp.timeIntervalSince(departureSince) >= 2
        } else {
            confirmed = sampleCount >= 4 && location.timestamp.timeIntervalSince(departureSince) >= 5 &&
                (departureCoordinate?.distance(to: location.coordinate) ?? 0) >= 25
        }
        if confirmed { deviationState = .offRoute }
        return confirmed
    }

    mutating func reset() {
        deviationState = .onRoute
        departureSince = nil
        sampleCount = 0
        lastSampleTimestamp = nil
        departurePosition = nil
        departureCoordinate = nil
        observedRouteID = nil
        detectsReverseTravel = false
    }

    private static func courseDifferenceFromRoute(
        _ location: NavigationLocation,
        route: NavigationRoute,
        projection: RouteProjection
    ) -> Double? {
        guard location.speed >= 2.5,
              location.course.isFinite,
              (0...360).contains(location.course),
              location.courseAccuracy < 0 || location.courseAccuracy <= 45,
              route.coordinates.indices.contains(projection.segment),
              route.coordinates.indices.contains(projection.segment + 1) else { return nil }

        let start = route.coordinates[projection.segment]
        let end = route.coordinates[projection.segment + 1]
        let dx = (end.longitude - start.longitude) * 111_320.0 *
            cos(location.coordinate.latitude * .pi / 180)
        let dy = (end.latitude - start.latitude) * 110_574.0
        let routeCourse = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let difference = abs(location.course - routeCourse)
        return min(difference, 360 - difference)
    }
}
