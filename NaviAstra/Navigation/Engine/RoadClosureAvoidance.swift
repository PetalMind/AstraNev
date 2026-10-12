import Foundation

/// Covers every line segment, including its endpoints. No sparse-point acceptance check.
nonisolated struct RoadClosureAvoidance: Sendable {
    static let halfWidthMeters = 12.0
    let geometry: [Coordinate]
    let polygons: [[[Double]]]

    init(geometry: [Coordinate]) throws {
        let valid = geometry.filter(\.isValidValhallaCoordinate)
        guard valid.count == geometry.count, valid.count >= 2 else { throw RoutingError.invalidResponse }
        var segments: [(Coordinate, Coordinate)] = []
        for pair in zip(valid, valid.dropFirst()) where pair.0.distance(to: pair.1) > 0.1 {
            segments.append(pair)
        }
        // Fail explicitly rather than silently truncate a closure to a handful of points.
        guard !segments.isEmpty, segments.count <= 256 else {
            throw ValhallaFeatureError.message("Geometria zamknięcia jest zbyt złożona, aby bezpiecznie wyznaczyć objazd.")
        }
        self.geometry = valid
        polygons = segments.map { a, b in
            let scale = max(1_000, 111_320 * abs(cos((a.latitude + b.latitude) / 2 * .pi / 180)))
            let dx = (b.longitude - a.longitude) * scale
            let dy = (b.latitude - a.latitude) * 110_574
            let length = hypot(dx, dy)
            let ux = dx / length, uy = dy / length
            let width = Self.halfWidthMeters
            func point(_ origin: Coordinate, along: Double, side: Double) -> [Double] {
                [origin.longitude + (ux * along - uy * side) / scale,
                 origin.latitude + (uy * along + ux * side) / 110_574]
            }
            let ring = [point(a, along: -width, side: width), point(b, along: width, side: width),
                        point(b, along: width, side: -width), point(a, along: -width, side: -width)]
            return ring + [ring[0]]
        }
        guard polygons.flatMap({ $0 }).allSatisfy({ pair in
            Coordinate(latitude: pair[1], longitude: pair[0]).isValidValhallaCoordinate
        }) else { throw RoutingError.invalidResponse }
    }

    func intersects(_ route: NavigationRoute) -> Bool {
        guard route.coordinates.count >= 2 else { return true }
        for (a, b) in zip(geometry, geometry.dropFirst()) {
            // An expanded bounding box eliminates most candidate segments on long routes.
            let latPad = Self.halfWidthMeters * 2 / 110_574
            let lonPad = Self.halfWidthMeters * 2 / max(1_000, 111_320 * abs(cos(a.latitude * .pi / 180)))
            for (c, d) in zip(route.coordinates, route.coordinates.dropFirst()) {
                guard max(c.latitude, d.latitude) >= min(a.latitude, b.latitude) - latPad,
                      min(c.latitude, d.latitude) <= max(a.latitude, b.latitude) + latPad,
                      max(c.longitude, d.longitude) >= min(a.longitude, b.longitude) - lonPad,
                      min(c.longitude, d.longitude) <= max(a.longitude, b.longitude) + lonPad else { continue }
                if Self.intersectsRectangle(a, b, c, d) { return true }
            }
        }
        return false
    }

    private static func intersectsRectangle(_ a: Coordinate, _ b: Coordinate,
                                            _ c: Coordinate, _ d: Coordinate) -> Bool {
        let scale = max(1_000, 111_320 * abs(cos((a.latitude + b.latitude) / 2 * .pi / 180)))
        let dx = (b.longitude - a.longitude) * scale, dy = (b.latitude - a.latitude) * 110_574
        let length = hypot(dx, dy)
        guard length > 0 else { return false }
        func local(_ point: Coordinate) -> (x: Double, y: Double) {
            let x = (point.longitude - a.longitude) * scale, y = (point.latitude - a.latitude) * 110_574
            return ((x * dx + y * dy) / length, (-x * dy + y * dx) / length)
        }
        let first = local(c), last = local(d), width = Self.halfWidthMeters
        var lower = 0.0, upper = 1.0
        // Clip the route segment against exactly the same rectangle sent to Valhalla.
        for (origin, delta, minimum, maximum) in [
            (first.x, last.x - first.x, -width, length + width),
            (first.y, last.y - first.y, -width, width)
        ] {
            if abs(delta) < 1e-12 {
                if origin < minimum || origin > maximum { return false }
            } else {
                let t1 = (minimum - origin) / delta, t2 = (maximum - origin) / delta
                lower = max(lower, min(t1, t2)); upper = min(upper, max(t1, t2))
                if lower > upper { return false }
            }
        }
        return true
    }
}
