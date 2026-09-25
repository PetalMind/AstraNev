import Foundation

/// Selects a useful traffic horizon and queries small boxes along the active route corridor.
struct RouteTrafficMonitor {
    static let lookAheadSeconds: TimeInterval = 25 * 60
    static let corridorHalfWidthMeters = 900.0
    static let querySegmentLengthMeters = 8_000.0
    static let queryOverlapMeters = 1_000.0
    static let routeMatchToleranceMeters = 140.0

    static func lookAheadDistance(for route: NavigationRoute, progress: RouteProgress?) -> Double {
        let remainingDistance = max(0, progress?.remainingDistance ?? route.distance)
        let remainingTime = max(0, progress?.remainingTime ?? route.expectedTravelTime)
        guard remainingDistance > 0 else { return 0 }
        let averageSpeedKph = remainingTime > 0
            ? remainingDistance / remainingTime * 3.6
            : 60
        let timeHorizonDistance = averageSpeedKph / 3.6 * lookAheadSeconds
        let distanceCap: Double
        if averageSpeedKph < 45 {
            distanceCap = 18_000
        } else if averageSpeedKph < 85 {
            distanceCap = 35_000
        } else {
            distanceCap = 100_000
        }
        return min(remainingDistance, min(timeHorizonDistance, distanceCap))
    }

    static func queryBoxes(for route: NavigationRoute, from startDistance: Double,
                           through endDistance: Double,
                           corridorHalfWidthMeters: Double = corridorHalfWidthMeters) -> [TrafficBoundingBox] {
        guard route.coordinates.count > 1, endDistance > startDistance else { return [] }
        let start = max(0, startDistance)
        let end = min(routeGeometryLength(route), endDistance)
        guard end > start else { return [] }

        var boxes: [TrafficBoundingBox] = []
        var segmentStart = start
        while segmentStart < end {
            let segmentEnd = min(end, segmentStart + querySegmentLengthMeters)
            let coordinates = coordinates(in: route, from: segmentStart, through: segmentEnd)
            if !coordinates.isEmpty {
                boxes.append(boundingBox(around: coordinates, halfWidthMeters: corridorHalfWidthMeters))
            }
            if segmentEnd >= end { break }
            segmentStart = max(segmentStart + 1, segmentEnd - queryOverlapMeters)
        }
        return boxes
    }

    static func matching(_ incidents: [TrafficIncident], to route: NavigationRoute,
                         from startDistance: Double, through endDistance: Double,
                         routeMatchToleranceMeters: Double = routeMatchToleranceMeters) -> [TrafficIncident] {
        var matched: [String: TrafficIncident] = [:]
        for incident in incidents {
            let geometry = incident.geometry.isEmpty ? [incident.coordinate] : incident.geometry
            let candidates = geometry.compactMap { coordinate -> (Coordinate, RouteProjection)? in
                guard let projection = MapMatcher.project(coordinate, onto: route.coordinates) else { return nil }
                return (coordinate, projection)
            }.filter { candidate in
                candidate.1.distanceFromRoute <= routeMatchToleranceMeters &&
                    candidate.1.alongRoute >= startDistance - 100 &&
                    candidate.1.alongRoute <= endDistance + 100
            }
            let best = candidates.first(where: { $0.0 == incident.coordinate }) ?? candidates.min(by: {
                if $0.1.distanceFromRoute == $1.1.distanceFromRoute {
                    return abs($0.1.alongRoute - startDistance) < abs($1.1.alongRoute - startDistance)
                }
                return $0.1.distanceFromRoute < $1.1.distanceFromRoute
            })
            guard let best else { continue }

            let routeIncident = TrafficIncident(
                id: incident.id,
                description: incident.description,
                coordinate: best.0,
                delaySeconds: incident.delaySeconds,
                category: incident.category,
                severity: incident.severity,
                geometry: incident.geometry,
                distanceAlongRoute: best.1.alongRoute)
            if let existing = matched[incident.id],
               (existing.distanceAlongRoute ?? .infinity) <= best.1.alongRoute { continue }
            matched[incident.id] = routeIncident
        }
        return matched.values.sorted { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
    }

    private static func routeGeometryLength(_ route: NavigationRoute) -> Double {
        zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private static func coordinates(in route: NavigationRoute, from start: Double,
                                    through end: Double) -> [Coordinate] {
        guard route.coordinates.count > 1, end > start else { return [] }
        var result: [Coordinate] = []
        var segmentStart = 0.0
        for (first, second) in zip(route.coordinates, route.coordinates.dropFirst()) {
            let segmentLength = first.distance(to: second)
            let segmentEnd = segmentStart + segmentLength
            if segmentLength > 0, segmentEnd >= start, segmentStart <= end {
                let lower = max(0, min(1, (start - segmentStart) / segmentLength))
                let upper = max(0, min(1, (end - segmentStart) / segmentLength))
                if upper >= lower {
                    append(interpolate(first, second, fraction: lower), to: &result)
                    if lower == 0 { append(first, to: &result) }
                    if upper == 1 { append(second, to: &result) }
                    append(interpolate(first, second, fraction: upper), to: &result)
                }
            }
            segmentStart = segmentEnd
            if segmentStart >= end { break }
        }
        return result
    }

    private static func append(_ coordinate: Coordinate, to coordinates: inout [Coordinate]) {
        if coordinates.last != coordinate { coordinates.append(coordinate) }
    }

    private static func interpolate(_ first: Coordinate, _ second: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(latitude: first.latitude + (second.latitude - first.latitude) * fraction,
                   longitude: first.longitude + (second.longitude - first.longitude) * fraction)
    }

    private static func boundingBox(around coordinates: [Coordinate], halfWidthMeters: Double) -> TrafficBoundingBox {
        let minimumLatitude = coordinates.map(\.latitude).min() ?? 0
        let maximumLatitude = coordinates.map(\.latitude).max() ?? 0
        let minimumLongitude = coordinates.map(\.longitude).min() ?? 0
        let maximumLongitude = coordinates.map(\.longitude).max() ?? 0
        let meanLatitude = (minimumLatitude + maximumLatitude) / 2
        let latitudePadding = halfWidthMeters / 111_320
        let longitudePadding = halfWidthMeters / max(1_000, 111_320 * abs(cos(meanLatitude * .pi / 180)))
        return TrafficBoundingBox(minLongitude: minimumLongitude - longitudePadding,
                                  minLatitude: minimumLatitude - latitudePadding,
                                  maxLongitude: maximumLongitude + longitudePadding,
                                  maxLatitude: maximumLatitude + latitudePadding)
    }
}
