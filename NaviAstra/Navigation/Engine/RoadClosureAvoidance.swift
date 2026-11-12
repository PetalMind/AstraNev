import Foundation

/// The closed [longitude, latitude] ring used in the request and in local route validation.
nonisolated struct RoadExclusionPolygon: Sendable {
    // A submillimetre margin keeps rounding at an edge or vertex on the excluded side.
    private static let boundaryTolerance = 1e-9
    let ring: [[Double]]
    private let vertices: [Coordinate]
    private let latitudes: ClosedRange<Double>
    private let longitudes: ClosedRange<Double>

    init(ring: [[Double]]) throws {
        guard ring.count >= 4, ring.first == ring.last, ring.allSatisfy({ point in
            point.count == 2 && Coordinate(latitude: point[1], longitude: point[0]).isValidValhallaCoordinate
        }) else { throw RoutingError.invalidResponse }
        self.ring = ring
        // Work on one continuous longitude axis, including for corridors straddling the date line.
        let reference = ring[0][0]
        let points = ring.map {
            Coordinate(latitude: $0[1], longitude: reference + Self.longitudeDelta($0[0] - reference))
        }
        vertices = points
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        latitudes = (lats.min()! - Self.boundaryTolerance)...(lats.max()! + Self.boundaryTolerance)
        longitudes = (lons.min()! - Self.boundaryTolerance)...(lons.max()! + Self.boundaryTolerance)
        let twiceArea = zip(points, points.dropFirst()).reduce(0.0) { area, edge in
            area + Self.orientation(points[0], edge.0, edge.1)
        }
        guard twiceArea != 0, longitudes.upperBound - longitudes.lowerBound < 180 else {
            throw ValhallaFeatureError.message("Nie można sprawdzić geometrii omijanego obszaru.")
        }
    }

    private enum Contact {
        case clear, invalid, point(Coordinate)
    }

    func intersects(_ route: NavigationRoute) -> Bool {
        if case .clear = contact(with: route) { return false }
        return true
    }

    /// Small search hint at a real conflict. Acceptance still checks the original ring.
    func localizedBarrier(on route: NavigationRoute) -> [[Double]]? {
        guard case .point(let point) = contact(with: route) else { return nil }
        let width = RoadClosureAvoidance.halfWidthMeters
        let latitudeRadius = width / 110_574
        let longitudeRadius = width / max(1_000, 111_320 * abs(cos(point.latitude * .pi / 180)))
        let west = Self.longitudeDelta(point.longitude - longitudeRadius)
        let east = Self.longitudeDelta(point.longitude + longitudeRadius)
        let south = max(-90, point.latitude - latitudeRadius)
        let north = min(90, point.latitude + latitudeRadius)
        return [[west, south], [east, south], [east, north], [west, north], [west, south]]
    }

    private func contact(with route: NavigationRoute) -> Contact {
        guard route.coordinates.count >= 2, let first = route.coordinates.first,
              first.isValidValhallaCoordinate else { return .invalid }
        let center = (longitudes.lowerBound + longitudes.upperBound) / 2
        let start = Coordinate(latitude: first.latitude, longitude: center + Self.longitudeDelta(first.longitude - center))
        if contains(start) { return .point(first) }
        for (a, b) in zip(route.coordinates, route.coordinates.dropFirst()) {
            guard b.isValidValhallaCoordinate else { return .invalid }
            guard min(a.latitude, b.latitude) <= latitudes.upperBound,
                  max(a.latitude, b.latitude) >= latitudes.lowerBound else { continue }
            let delta = Self.longitudeDelta(b.longitude - a.longitude)
            let midpoint = a.longitude + delta / 2
            let shift = 360 * ((center - midpoint) / 360).rounded()
            let c = Coordinate(latitude: a.latitude, longitude: a.longitude + shift)
            let d = Coordinate(latitude: b.latitude, longitude: a.longitude + shift + delta)
            guard min(c.longitude, d.longitude) <= longitudes.upperBound,
                  max(c.longitude, d.longitude) >= longitudes.lowerBound else { continue }
            for (p, q) in zip(vertices, vertices.dropFirst()) where Self.segmentsIntersect(c, d, p, q) {
                // Signed distances to the edge interpolate linearly along the route segment.
                let before = Self.orientation(p, q, c), after = Self.orientation(p, q, d)
                let fraction: Double
                if before != after {
                    fraction = before / (before - after)
                } else {
                    // Collinear overlap. Use the near end of the overlapping interval.
                    let dx = d.longitude - c.longitude, dy = d.latitude - c.latitude
                    if abs(dx) >= abs(dy), dx != 0 {
                        fraction = min((p.longitude - c.longitude) / dx, (q.longitude - c.longitude) / dx)
                    } else if dy != 0 {
                        fraction = min((p.latitude - c.latitude) / dy, (q.latitude - c.latitude) / dy)
                    } else { fraction = 0 }
                }
                let t = min(1, max(0, fraction))
                return .point(Coordinate(latitude: c.latitude + t * (d.latitude - c.latitude),
                    longitude: Self.longitudeDelta(c.longitude + t * (d.longitude - c.longitude))))
            }
        }
        return .clear
    }

    fileprivate static func longitudeDelta(_ value: Double) -> Double {
        if value > 180 { return value - 360 }
        if value < -180 { return value + 360 }
        return value
    }

    private func contains(_ point: Coordinate) -> Bool {
        guard latitudes.contains(point.latitude), longitudes.contains(point.longitude) else { return false }
        var inside = false
        for (p, q) in zip(vertices, vertices.dropFirst())
            where (p.latitude > point.latitude) != (q.latitude > point.latitude) {
            let fraction = (point.latitude - p.latitude) / (q.latitude - p.latitude)
            if point.longitude < p.longitude + fraction * (q.longitude - p.longitude) { inside.toggle() }
        }
        return inside
    }

    private static func orientation(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
        (b.longitude - a.longitude) * (c.latitude - a.latitude)
            - (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    private static func segmentsIntersect(_ a: Coordinate, _ b: Coordinate,
                                          _ c: Coordinate, _ d: Coordinate) -> Bool {
        // Inclusive bounds also cover touching a vertex or following the boundary.
        guard min(a.longitude, b.longitude) <= max(c.longitude, d.longitude) + boundaryTolerance,
              min(c.longitude, d.longitude) <= max(a.longitude, b.longitude) + boundaryTolerance,
              min(a.latitude, b.latitude) <= max(c.latitude, d.latitude) + boundaryTolerance,
              min(c.latitude, d.latitude) <= max(a.latitude, b.latitude) + boundaryTolerance else { return false }
        func straddles(_ p: Coordinate, _ q: Coordinate, _ first: Coordinate, _ last: Coordinate) -> Bool {
            let tolerance = boundaryTolerance * (abs(q.longitude - p.longitude) + abs(q.latitude - p.latitude))
            let side1 = orientation(p, q, first), side2 = orientation(p, q, last)
            return min(side1, side2) <= tolerance && max(side1, side2) >= -tolerance
        }
        return straddles(a, b, c, d) && straddles(c, d, a, b)
    }
}

/// Covers every line segment, including its endpoints. The request budget never truncates local evidence.
nonisolated struct RoadClosureAvoidance: Sendable {
    static let halfWidthMeters = 12.0
    let exclusions: [RoadExclusionPolygon]
    var polygons: [[[Double]]] { exclusions.map(\.ring) }

    init(geometry: [Coordinate]) throws {
        guard geometry.count >= 2, geometry.allSatisfy(\.isValidValhallaCoordinate) else {
            throw RoutingError.invalidResponse
        }
        var exclusions: [RoadExclusionPolygon] = []
        for (a, b) in zip(geometry, geometry.dropFirst()) where a.distance(to: b) > 0.1 {
            let scale = max(1_000, 111_320 * abs(cos((a.latitude + b.latitude) / 2 * .pi / 180)))
            let dx = RoadExclusionPolygon.longitudeDelta(b.longitude - a.longitude) * scale
            let dy = (b.latitude - a.latitude) * 110_574
            let length = hypot(dx, dy)
            let ux = dx / length, uy = dy / length
            let width = Self.halfWidthMeters
            func point(_ origin: Coordinate, along: Double, side: Double) -> [Double] {
                [RoadExclusionPolygon.longitudeDelta(origin.longitude + (ux * along - uy * side) / scale),
                 origin.latitude + (uy * along + ux * side) / 110_574]
            }
            let ring = [point(a, along: -width, side: width), point(b, along: width, side: width),
                        point(b, along: width, side: -width), point(a, along: -width, side: -width)]
            exclusions.append(try RoadExclusionPolygon(ring: ring + [ring[0]]))
        }
        guard !exclusions.isEmpty else {
            throw ValhallaFeatureError.message("Nie można sprawdzić przebiegu zamkniętego odcinka drogi.")
        }
        self.exclusions = exclusions
    }

    func intersects(_ route: NavigationRoute) -> Bool {
        exclusions.contains { $0.intersects(route) }
    }
}
