import Foundation

nonisolated struct RouteTrafficFlowQuery: Sendable {
    let distanceAlongRoute: Double
    let coordinate: Coordinate
}

nonisolated struct RouteTrafficFlowSample: Sendable {
    let distanceAlongRoute: Double
    let flow: TrafficFlow
}

nonisolated struct RouteTrafficSegment: Equatable, Sendable, Identifiable {
    let id: String
    let routeID: UUID
    let startDistance: Double
    let endDistance: Double
    let coordinates: [Coordinate]
    let colorHex: UInt32
    let isRoadClosure: Bool
    var currentSpeedKph: Double? = nil
    var freeFlowSpeedKph: Double? = nil
}

/// Selects a useful traffic horizon and queries small boxes along the active route corridor.
struct RouteTrafficMonitor {
    static let lookAheadSeconds: TimeInterval = 25 * 60
    nonisolated static let corridorHalfWidthMeters = 900.0
    nonisolated static let querySegmentLengthMeters = 8_000.0
    nonisolated static let queryOverlapMeters = 1_000.0
    nonisolated static let routeMatchToleranceMeters = 140.0
    nonisolated static let maximumFlowSamples = 20
    nonisolated static let flowSampleSpacingMeters = 900.0

    /// A nearby point is not evidence that the route uses the affected road.
    /// Require a continuous, aligned overlap; point-only closures remain map context.
    nonisolated static func incidentProjection(_ incident: TrafficIncident,
                                               geometry: RouteProgressGeometry) -> RouteProjection? {
        let points = incident.geometry.isEmpty ? [incident.coordinate] : incident.geometry
        if points.count == 1 {
            guard !incident.isRoadClosure, let projection = geometry.project(points[0]),
                  projection.distanceFromRoute <= 20 else { return nil }
            return projection
        }
        return overlapProjection(points, geometry: geometry,
                                 tolerance: incident.isRoadClosure ? 10 : 20)
    }

    nonisolated static func overlapProjection(_ points: [Coordinate], geometry: RouteProgressGeometry,
                                              tolerance: Double = 10) -> RouteProjection? {
        var run = 0.0
        var bestRun = 0.0
        var first: RouteProjection?
        var best: RouteProjection?
        let length = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        guard length >= 8 else { return nil }
        for (a, b) in zip(points, points.dropFirst()) {
            let segmentLength = a.distance(to: b)
            guard segmentLength > 0 else { continue }
            let count = max(1, Int(ceil(segmentLength / 15)))
            for index in 0..<count {
                let fraction = (Double(index) + 0.5) / Double(count)
                let point = Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                       longitude: a.longitude + (b.longitude - a.longitude) * fraction)
                guard let projection = geometry.project(point), projection.distanceFromRoute <= tolerance,
                      let before = geometry.coordinate(at: max(0, projection.alongRoute - 6)),
                      let after = geometry.coordinate(at: min(geometry.length, projection.alongRoute + 6)),
                      RoadGeometryAlignment.isAligned(a, b, before, after) else {
                    run = 0
                    first = nil
                    continue
                }
                if first == nil { first = projection }
                run += segmentLength / Double(count)
                if run > bestRun { bestRun = run; best = first }
            }
        }
        guard bestRun >= min(30, length * 0.8) else { return nil }
        return best
    }

    nonisolated static func flowQueries(for routeCoordinates: [Coordinate], from startDistance: Double,
                                        through endDistance: Double) -> [RouteTrafficFlowQuery] {
        let routeLength = routeGeometryLength(routeCoordinates)
        let start = max(0, startDistance)
        let end = min(routeLength, endDistance)
        guard routeCoordinates.count > 1, end > start else { return [] }
        let requestedCount = Int(ceil((end - start) / flowSampleSpacingMeters)) + 1
        let sampleCount = min(maximumFlowSamples, max(1, requestedCount))
        let distances: [Double]
        if sampleCount == 1 {
            distances = [(start + end) / 2]
        } else {
            let spacing = (end - start) / Double(sampleCount - 1)
            distances = (0..<sampleCount).map { start + Double($0) * spacing }
        }
        return distances.compactMap { distance in
            guard let coordinate = coordinate(at: distance, in: routeCoordinates) else { return nil }
            return RouteTrafficFlowQuery(distanceAlongRoute: distance, coordinate: coordinate)
        }
    }

    nonisolated static func coloredSegments(on route: NavigationRoute, from startDistance: Double,
                                            through endDistance: Double,
                                            queries: [RouteTrafficFlowQuery],
                                            samples: [RouteTrafficFlowSample],
                                            geometry: RouteProgressGeometry) -> [RouteTrafficSegment] {
        guard queries.count > 0, !samples.isEmpty else { return [] }
        let routeLength = geometry.length
        let start = max(0, startDistance)
        let end = min(routeLength, endDistance)
        guard end > start else { return [] }
        let orderedQueries = queries.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        let orderedSamples = samples.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        return orderedSamples.compactMap { sample in
            guard sample.flow.confidence.map({ $0 >= 0.5 }) ?? true else { return nil }
            guard overlapProjection(sample.flow.coordinates, geometry: geometry) != nil else { return nil }
            guard let index = orderedQueries.firstIndex(where: {
                abs($0.distanceAlongRoute - sample.distanceAlongRoute) < 1
            }) else { return nil }
            let cellStart = index == 0 ? start
                : (orderedQueries[index - 1].distanceAlongRoute + sample.distanceAlongRoute) / 2
            let cellEnd = index == orderedQueries.count - 1 ? end
                : (sample.distanceAlongRoute + orderedQueries[index + 1].distanceAlongRoute) / 2
            let projections = sample.flow.coordinates.compactMap { coordinate -> RouteProjection? in
                guard let projection = geometry.project(coordinate),
                      projection.distanceFromRoute <= routeMatchToleranceMeters,
                      projection.alongRoute >= cellStart - 100,
                      projection.alongRoute <= cellEnd + 100 else { return nil }
                return projection
            }
            guard let first = projections.map(\.alongRoute).min(),
                  let last = projections.map(\.alongRoute).max() else { return nil }
            let clippedStart = max(start, max(cellStart, first))
            let clippedEnd = min(end, min(cellEnd, last))
            guard clippedEnd - clippedStart > 8 else { return nil }
            let coordinates = coordinates(in: route.coordinates, from: clippedStart, through: clippedEnd)
            guard coordinates.count > 1 else { return nil }
            return RouteTrafficSegment(
                id: "\(route.id.uuidString)-\(Int(clippedStart.rounded()))-\(Int(clippedEnd.rounded()))",
                routeID: route.id,
                startDistance: clippedStart,
                endDistance: clippedEnd,
                coordinates: coordinates,
                colorHex: sample.flow.overlayColorHex,
                isRoadClosure: sample.flow.roadClosure,
                currentSpeedKph: Double(sample.flow.currentSpeedKph),
                freeFlowSpeedKph: Double(sample.flow.freeFlowSpeedKph))
        }
    }

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

    nonisolated static func queryBoxes(for routeCoordinates: [Coordinate], from startDistance: Double,
                           through endDistance: Double,
                           corridorHalfWidthMeters: Double = corridorHalfWidthMeters) -> [TrafficBoundingBox] {
        guard routeCoordinates.count > 1, endDistance > startDistance else { return [] }
        let start = max(0, startDistance)
        let end = min(routeGeometryLength(routeCoordinates), endDistance)
        guard end > start else { return [] }

        var boxes: [TrafficBoundingBox] = []
        var segmentStart = start
        while segmentStart < end {
            let segmentEnd = min(end, segmentStart + querySegmentLengthMeters)
            let coordinates = coordinates(in: routeCoordinates, from: segmentStart, through: segmentEnd)
            if !coordinates.isEmpty {
                boxes.append(boundingBox(around: coordinates, halfWidthMeters: corridorHalfWidthMeters))
            }
            if segmentEnd >= end { break }
            segmentStart = max(segmentStart + 1, segmentEnd - queryOverlapMeters)
        }
        return boxes
    }

    nonisolated static func matching(_ incidents: [TrafficIncident], to route: NavigationRoute,
                                     from startDistance: Double, through endDistance: Double,
                                     routeMatchToleranceMeters: Double = routeMatchToleranceMeters,
                                     routeGeometry: RouteProgressGeometry) -> [TrafficIncident] {
        var matched: [String: TrafficIncident] = [:]
        for incident in incidents {
            guard let best = incidentProjection(incident, geometry: routeGeometry),
                  best.alongRoute >= startDistance - 100, best.alongRoute <= endDistance + 100 else { continue }

            let routeIncident = TrafficIncident(
                id: incident.id,
                description: incident.description,
                coordinate: best.coordinate,
                delaySeconds: incident.delaySeconds,
                category: incident.category,
                severity: incident.severity,
                geometry: incident.geometry,
                distanceAlongRoute: best.alongRoute)
            if let existing = matched[incident.id],
               (existing.distanceAlongRoute ?? .infinity) <= best.alongRoute { continue }
            matched[incident.id] = routeIncident
        }
        return matched.values.sorted { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
    }

    private nonisolated static func routeGeometryLength(_ routeCoordinates: [Coordinate]) -> Double {
        zip(routeCoordinates, routeCoordinates.dropFirst())
            .reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private nonisolated static func coordinates(in routeCoordinates: [Coordinate], from start: Double,
                                    through end: Double) -> [Coordinate] {
        guard routeCoordinates.count > 1, end > start else { return [] }
        var result: [Coordinate] = []
        var segmentStart = 0.0
        for (first, second) in zip(routeCoordinates, routeCoordinates.dropFirst()) {
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

    private nonisolated static func coordinate(at distance: Double,
                                               in routeCoordinates: [Coordinate]) -> Coordinate? {
        guard routeCoordinates.count > 1 else { return routeCoordinates.first }
        var distanceBeforeSegment = 0.0
        for (first, second) in zip(routeCoordinates, routeCoordinates.dropFirst()) {
            let segmentLength = first.distance(to: second)
            if segmentLength > 0, distance <= distanceBeforeSegment + segmentLength {
                let fraction = max(0, min(1, (distance - distanceBeforeSegment) / segmentLength))
                return interpolate(first, second, fraction: fraction)
            }
            distanceBeforeSegment += segmentLength
        }
        return routeCoordinates.last
    }

    private nonisolated static func append(_ coordinate: Coordinate, to coordinates: inout [Coordinate]) {
        if coordinates.last != coordinate { coordinates.append(coordinate) }
    }

    private nonisolated static func interpolate(_ first: Coordinate, _ second: Coordinate,
                                                fraction: Double) -> Coordinate {
        Coordinate(latitude: first.latitude + (second.latitude - first.latitude) * fraction,
                   longitude: first.longitude + (second.longitude - first.longitude) * fraction)
    }

    private nonisolated static func boundingBox(around coordinates: [Coordinate],
                                               halfWidthMeters: Double) -> TrafficBoundingBox {
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

nonisolated enum RoadGeometryAlignment {
    static func isAligned(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate, _ d: Coordinate,
                          directed: Bool = false) -> Bool {
        let scale = cos(a.latitude * .pi / 180)
        let x1 = (b.longitude - a.longitude) * scale, y1 = b.latitude - a.latitude
        let x2 = (d.longitude - c.longitude) * scale, y2 = d.latitude - c.latitude
        let denominator = hypot(x1, y1) * hypot(x2, y2)
        guard denominator > 0 else { return false }
        let dot = (x1 * x2 + y1 * y2) / denominator
        return (directed ? dot : abs(dot)) >= cos(30 * .pi / 180)
    }
}
