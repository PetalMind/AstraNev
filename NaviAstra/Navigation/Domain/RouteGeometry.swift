import Foundation

struct RouteLegGeometry {
    let targetID: UUID?
    let active: [Coordinate]
    let continuation: [Coordinate]
}

struct RouteGeometrySplit {
    let completed: [Coordinate]
    let remaining: [Coordinate]
}

enum RouteGeometrySplitter {
    static func length(of coordinates: [Coordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst())
            .reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func split(_ coordinates: [Coordinate], atDistance distance: Double) -> RouteGeometrySplit {
        guard coordinates.count > 1 else {
            return RouteGeometrySplit(completed: [], remaining: coordinates)
        }

        let target = max(0, distance.isFinite ? distance : 0)
        let totalLength = length(of: coordinates)
        guard target > 0 else {
            return RouteGeometrySplit(completed: [], remaining: coordinates)
        }
        guard target < totalLength else {
            return RouteGeometrySplit(completed: coordinates, remaining: [])
        }

        var traversed = 0.0
        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let segmentLength = start.distance(to: end)
            guard segmentLength > 0 else { continue }
            if traversed + segmentLength >= target {
                let fraction = (target - traversed) / segmentLength
                let boundary = Coordinate(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction)
                var completed = Array(coordinates.prefix(index + 1))
                if (completed.last?.distance(to: boundary) ?? .infinity) > 0.5 {
                    completed.append(boundary)
                }
                var remaining = [boundary]
                for coordinate in coordinates.dropFirst(index + 1) where
                    (remaining.last?.distance(to: coordinate) ?? .infinity) > 0.5 {
                    remaining.append(coordinate)
                }
                return RouteGeometrySplit(completed: completed, remaining: remaining)
            }
            traversed += segmentLength
        }

        return RouteGeometrySplit(completed: coordinates, remaining: [])
    }
}

enum RouteMapGeometry {
    static func activeLeg(in route: [Coordinate], from position: Coordinate?, through stops: [Destination]) -> RouteLegGeometry {
        guard route.count > 1 else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }
        guard !stops.isEmpty else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }

        let currentDistance = position.flatMap { MapMatcher.project($0, onto: route)?.alongRoute } ?? 0
        let nextStop = stops
            .compactMap { stop -> (Destination, RouteProjection)? in
                guard let projection = MapMatcher.project(stop.coordinate, onto: route),
                      projection.distanceFromRoute <= 1_000,
                      projection.alongRoute > currentDistance + 30 else { return nil }
                return (stop, projection)
            }
            .min { $0.1.alongRoute < $1.1.alongRoute }

        guard let (stop, projection) = nextStop else {
            return RouteLegGeometry(targetID: nil, active: route, continuation: [])
        }

        let segment = min(projection.segment, route.count - 2)
        var active = Array(route.prefix(segment + 1))
        if active.last?.distance(to: projection.coordinate) ?? .infinity > 0.5 {
            active.append(projection.coordinate)
        }

        var continuation = [projection.coordinate]
        for coordinate in route.dropFirst(segment + 1) {
            if continuation.last?.distance(to: coordinate) ?? .infinity > 0.5 {
                continuation.append(coordinate)
            }
        }

        return RouteLegGeometry(targetID: stop.id, active: active, continuation: continuation)
    }

    static func dashedSegments(_ coordinates: [Coordinate], dashLength: Double = 18, gapLength: Double = 10) -> [[Coordinate]] {
        guard coordinates.count > 1 else { return [] }
        var segments: [[Coordinate]] = []
        var current: [Coordinate] = []
        var drawing = true
        var remaining = dashLength

        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let length = start.distance(to: end)
            guard length > 0 else { continue }
            var consumed = 0.0

            while consumed < length {
                let step = min(remaining, length - consumed)
                let from = interpolate(start, end, fraction: consumed / length)
                let to = interpolate(start, end, fraction: (consumed + step) / length)
                if drawing {
                    if current.isEmpty {
                        current.append(from)
                    } else if current.last!.distance(to: from) > 0.5 {
                        current.append(from)
                    }
                    current.append(to)
                }

                consumed += step
                remaining -= step
                if remaining <= 0.0001 {
                    if drawing, current.count > 1 { segments.append(current) }
                    if drawing { current = [] }
                    drawing.toggle()
                    remaining = drawing ? dashLength : gapLength
                }
            }
        }

        if drawing, current.count > 1 { segments.append(current) }
        return segments
    }

    private static func interpolate(_ start: Coordinate, _ end: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                   longitude: start.longitude + (end.longitude - start.longitude) * fraction)
    }
}

struct RouteProgress {
    var traveledDistance: Double
    var remainingDistance: Double
    var remainingTime: TimeInterval
    var distanceToNextManeuver: Double
    var nextManeuver: Maneuver?
    var geometryProgress: Double = 0
    var geometryRouteID: UUID?
}
