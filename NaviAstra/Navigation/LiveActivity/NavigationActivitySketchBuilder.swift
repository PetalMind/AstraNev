import Foundation

nonisolated enum NavigationActivitySketchBuilder {
    /// The diagram follows the already calculated path. Distances shown elsewhere
    /// still come from the routing provider, never from this drawing's bounds.
    static func make(route: NavigationRoute, progress: RouteProgress,
                     location: Coordinate?, course: Double?) -> NavigationActivityRouteSketch? {
        if let journey = route.journey, journey.legs.contains(where: { !$0.hasResolvedRouteGeometry }) { return nil }
        let geometry = RouteProgressGeometry(route)
        guard geometry.length > 0, route.coordinates.count > 1 else { return nil }
        let along: Double
        if let location {
            guard let projection = geometry.project(location, within: 100), projection.distanceFromRoute <= 100 else { return nil }
            along = projection.alongRoute
        } else {
            let total = progress.traveledDistance + progress.remainingDistance
            guard total.isFinite, total > 0 else { return nil }
            along = geometry.length * min(1, max(0, progress.traveledDistance / total))
        }
        let start = max(0, along - 100)
        let end = min(geometry.length, along + max(500, min(1_400,
            progress.distanceToNextManeuver.isFinite ? progress.distanceToNextManeuver + 200 : 900)))
        guard end > start, let center = geometry.coordinate(at: along) else { return nil }
        var coordinates: [Coordinate] = []
        for index in 0..<36 {
            if let point = geometry.coordinate(at: start + (end - start) * Double(index) / 35) { coordinates.append(point) }
        }
        let maneuverCoordinate = progress.nextManeuver.flatMap { maneuver in
            route.coordinates.indices.contains(maneuver.shapeIndex) ? route.coordinates[maneuver.shapeIndex] : nil
        }
        let bearing = course.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil }
            ?? geometry.bearing(at: along, lookAhead: 40) ?? 0
        let angle = bearing * .pi / 180
        func local(_ coordinate: Coordinate) -> (Double, Double) {
            let east = (coordinate.longitude - center.longitude) * 111_320 * cos(center.latitude * .pi / 180)
            let north = (coordinate.latitude - center.latitude) * 110_574
            return (east * cos(angle) - north * sin(angle), -(east * sin(angle) + north * cos(angle)))
        }
        let path = coordinates.map(local)
        let minX = min(0, path.map(\.0).min() ?? 0), maxX = max(0, path.map(\.0).max() ?? 0)
        let minY = min(0, path.map(\.1).min() ?? 0), maxY = max(0, path.map(\.1).max() ?? 0)
        let span = max(150, max(maxX - minX, maxY - minY))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        func point(_ pair: (Double, Double)) -> NavigationActivityRouteSketch.Point {
            .init(x: Int((500 + (pair.0 - midX) / span * 800).rounded()),
                  y: Int((500 + (pair.1 - midY) / span * 800).rounded()))
        }
        let marker = maneuverCoordinate.flatMap { coordinate -> NavigationActivityRouteSketch.Point? in
            guard let projection = geometry.project(coordinate, within: 30), projection.alongRoute >= start,
                  projection.alongRoute <= end else { return nil }
            return point(local(coordinate))
        }
        return .init(points: path.map(point), puck: point((0, 0)), maneuver: marker)
    }
}
