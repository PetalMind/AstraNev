import Foundation

/// Associates a device with a road before checking the user's route. The nearest
/// route alone cannot distinguish neighboring carriageways or a service road.
nonisolated enum RoadAlertRoadResolver {
    static func context(at point: Coordinate, roads: [OSMRoadSpeedSegment],
                        requireDirection: Bool) -> RoadSignRouteContext? {
        let candidates = roads.compactMap { road -> (OSMRoadSpeedSegment, Double)? in
            guard let match = MapMatcher.project(point, onto: road.coordinates),
                  match.distanceFromRoute <= 25 else { return nil }
            return (road, match.distanceFromRoute)
        }.sorted { $0.1 < $1.1 }
        guard let best = candidates.first,
              candidates.count == 1 || candidates[1].1 > best.1 + 3 else { return nil }
        let direction: Bool?
        switch best.0.tags["oneway"] {
        case "yes", "1", "true": direction = true
        case "-1": direction = false
        default:
            if best.0.tags["junction"] == "roundabout" { direction = true }
            else if requireDirection { return nil }
            else { direction = nil }
        }
        return RoadSignRouteContext(road: best.0.coordinates, forward: direction,
                                    travelBearing: nil, roadID: best.0.id)
    }

    static func belongsToRoute(_ context: RoadSignRouteContext, at point: Coordinate,
                               route: [Coordinate], roads: [OSMRoadSpeedSegment]) -> Bool {
        guard let routePoint = MapMatcher.project(point, onto: route)?.coordinate,
              let selected = MapMatcher.project(routePoint, onto: context.road) else { return false }
        // Reject a parallel route that is closer to another mapped road, even if
        // both road centerlines fit the geometric tolerance.
        return !roads.contains { road in
            guard road.id != context.roadID,
                  let other = MapMatcher.project(routePoint, onto: road.coordinates) else { return false }
            return other.distanceFromRoute + 2 < selected.distanceFromRoute
        }
    }

    static func sectionType(at point: Coordinate, otherEnd: Coordinate,
                            context: RoadSignRouteContext) -> RoadAlertType? {
        guard let forward = context.forward,
              let here = MapMatcher.project(point, onto: context.road),
              let other = MapMatcher.project(otherEnd, onto: context.road),
              here.distanceFromRoute <= 25, other.distanceFromRoute <= 25,
              abs(here.alongRoute - other.alongRoute) > 3 else { return nil }
        return (forward ? here.alongRoute > other.alongRoute : here.alongRoute < other.alongRoute)
            ? .averageSpeedEnd : .averageSpeedStart
    }
}
