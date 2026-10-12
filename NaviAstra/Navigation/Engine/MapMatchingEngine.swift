import Foundation

nonisolated enum RouteDeviationState: String, Codable, Sendable {
    case onRoute, suspicious, probablyOffRoute, offRoute
}

nonisolated struct MapMatchingResult: Sendable {
    let match: RouteMatch
    let roadBearing: Double
    let roadName: String?
    let ambiguous: Bool
    let candidateCount: Int
    var matchedCoordinate: Coordinate { match.projection.coordinate }
    var progress: Double { match.projection.alongRoute }
}

/// Matches to route geometry, not to an independent map of all neighboring roads.
nonisolated enum MapMatchingEngine {
    static func stableProgress(result: MapMatchingResult?, projection: RouteProjection,
                               previous: RouteProjection?) -> RouteProjection {
        guard (result?.match.confidence ?? 0) >= 0.25, result?.ambiguous != true else { return previous ?? projection }
        return projection
    }

    static func match(route: NavigationRoute, geometry: RouteProgressGeometry,
                      location: NavigationLocation, previous: RouteProjection?,
                      previousTimestamp: Date?, now: Date = .now) -> MapMatchingResult? {
        guard location.coordinate.isValidValhallaCoordinate, location.accuracy.isFinite,
              (0...70).contains(location.accuracy), abs(now.timeIntervalSince(location.timestamp)) <= 15 else { return nil }
        let accuracy = max(8, location.accuracy), speed = location.speed.isFinite ? max(0, location.speed) : 0
        let elapsed = previousTimestamp.map { location.timestamp.timeIntervalSince($0) }
        let expected = elapsed.flatMap { delta -> Double? in
            guard delta > 0, delta <= 15, let previous else { return nil }
            return previous.alongRoute + speed * delta
        }
        let usesHeading = speed >= 1.5 && location.course.isFinite && (0..<360).contains(location.course) &&
            (location.courseAccuracy < 0 || location.courseAccuracy <= 45)
        let candidates = geometry.projections(near: location.coordinate, within: max(250, accuracy * 6))
        let ranked = candidates.compactMap { projection -> (RouteProjection, Double, Double)? in
            guard geometry.coordinates.indices.contains(projection.segment + 1) else { return nil }
            let a = geometry.coordinates[projection.segment], b = geometry.coordinates[projection.segment + 1]
            let dx = (b.longitude - a.longitude) * cos(location.coordinate.latitude * .pi / 180)
            let dy = b.latitude - a.latitude
            let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            var score = pow(projection.distanceFromRoute / accuracy, 2)
            if usesHeading {
                let difference = abs(location.course - bearing)
                score += pow(min(difference, 360 - difference) / 45, 2)
            }
            if let expected {
                let continuityScale = max(35, speed * (elapsed ?? 0) + accuracy * 2)
                score += pow((projection.alongRoute - expected) / continuityScale, 2) * 0.5
            }
            return (projection, score, bearing)
        }.sorted { $0.1 == $1.1 ? $0.0.segment < $1.0.segment : $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        let otherRoad = ranked.dropFirst().first {
            abs($0.0.alongRoute - best.0.alongRoute) > max(35, speed * 5) &&
                $0.0.coordinate.distance(to: best.0.coordinate) >= 5
        }
        let gap = otherRoad.map { max(0, $0.1 - best.1) }
        let ambiguous = gap.map { $0 < 1 } ?? false
        let ambiguityFactor = gap.map { min(1, 0.3 + $0 * 0.35) } ?? 1
        let confidence = exp(-0.5 * min(40, best.1)) * ambiguityFactor
        let roadName = route.maneuvers.filter { $0.shapeIndex <= best.0.segment }
            .max(by: { $0.shapeIndex < $1.shapeIndex })?.streetName
        return MapMatchingResult(match: RouteMatch(projection: best.0, confidence: confidence),
                                 roadBearing: best.2, roadName: roadName, ambiguous: ambiguous,
                                 candidateCount: ranked.count)
    }
}
