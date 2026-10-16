import Foundation

/// Shared presentation policy for signs, safety events and places. Road matching
/// is performed before this stage; presentation never turns proximity into relevance.
enum MapDisplayPriorityEngine {
    static func canPresentRouteAlerts(_ state: NavigationState, at now: Date = .now) -> Bool {
        guard state.status == .navigating || state.status == .rerouting,
              let route = state.route, let match = state.routeMatch,
              match.routeID == route.id, !match.isAmbiguous, match.match.confidence >= 0.65,
              match.match.projection.distanceFromRoute <= 12,
              let location = state.location, location.accuracy >= 0, location.accuracy <= 30,
              abs(now.timeIntervalSince(location.timestamp)) <= 10,
              abs(location.timestamp.timeIntervalSince(match.locationTimestamp)) <= 2 else { return false }
        if let roads = state.roadAlertRoadSegments, !roads.isEmpty {
            guard let driverRoad = RoadAlertRoadResolver.context(at: location.coordinate, roads: roads,
                                                                 requireDirection: false),
                  let position = MapMatcher.project(location.coordinate, onto: driverRoad.road),
                  driverRoad.applies(to: route.coordinates, at: position.coordinate),
                  RoadAlertRoadResolver.belongsToRoute(driverRoad, at: position.coordinate,
                                                       route: route.coordinates, roads: roads) else { return false }
        }
        let segment = match.match.projection.segment
        if location.speed >= 2, location.course.isFinite, (0..<360).contains(location.course),
           route.coordinates.indices.contains(segment + 1) {
            let radians = location.course * .pi / 180
            let end = Coordinate(latitude: location.coordinate.latitude + cos(radians) * 0.0001,
                                 longitude: location.coordinate.longitude + sin(radians) * 0.0001
                                     / max(0.1, cos(location.coordinate.latitude * .pi / 180)))
            guard RoadGeometryAlignment.isAligned(location.coordinate, end,
                route.coordinates[segment], route.coordinates[segment + 1], directed: true) else { return false }
        }
        return state.transportMode == .car
    }

    nonisolated static func priority(of alert: RoadSafetyAlert) -> Int {
        switch alert.type {
        case .roadClosed, .accident: return 950
        case .stopSign, .giveWaySign, .noEntrySign, .heightLimitSign, .weightLimitSign,
             .speedLimitSign, .speedLimitChange, .variableSpeedLimit: return 900
        case .speedCamera, .redLightCamera, .averageSpeedStart, .averageSpeedEnd: return 880
        case .trafficZoneSign, .railwayCrossing, .schoolZone, .dangerousCurve, .roadworks: return 850
        case .noOvertakingSign, .congestion: return 800
        case .trafficSign:
            let codes = Set(PolishRoadSign.codes(alert.signCode ?? ""))
            return codes.isDisjoint(with: ["C-12", "D-7", "D-9", "B-1", "B-3", "B-5", "D-51"])
                ? 300 : 850
        }
    }

    nonisolated static func warningDistance(for alert: RoadSafetyAlert, speed: Double) -> Double {
        let seconds = alert.type.isEnforcement ? 35.0 : 15.0
        return min(1_200, max(alert.type.isEnforcement ? 400 : 150, max(0, speed) * seconds))
    }

    static func upcomingAlerts(in state: NavigationState) -> [RoadSafetyAlert] {
        guard canPresentRouteAlerts(state) else { return [] }
        let traveled = state.roadAlertRouteDistance
        return state.roadSafetyAlerts.filter { alert in
            guard priority(of: alert) >= 800, let distance = alert.distanceAlongRoute else { return false }
            let ahead = distance - traveled
            return ahead >= 0 && ahead <= warningDistance(for: alert, speed: state.location?.speed ?? 0)
        }.sorted {
            let left = priority(of: $0), right = priority(of: $1)
            if left != right { return left > right }
            return ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity)
        }
    }

    nonisolated static func minimumZoom(for category: MapPOICategory) -> Int {
        switch category {
        case .transit, .attractions: 10
        case .fuel, .charging: 12
        case .parking, .lodging: 13
        case .shopping, .food, .health: 14
        }
    }

    static func passedSpeedLimit(in state: NavigationState) -> Int? {
        guard canPresentRouteAlerts(state), let location = state.location,
              let sign = state.roadSafetyAlerts.last(where: {
                  ($0.type == .speedLimitSign || $0.type == .trafficZoneSign
                   || PolishRoadSign.codes($0.signCode ?? "").contains("B-42"))
                    && ($0.distanceAlongRoute ?? .infinity) <= state.roadAlertRouteDistance - 3
              }), let value = sign.speedLimitKph, value > 0,
              Set(PolishRoadSign.codes(sign.signCode ?? "")).isDisjoint(with: ["B-34", "B-42", "B-44", "D-41", "D-43"]),
              let context = sign.signRouteContext,
              let roadPosition = MapMatcher.project(location.coordinate, onto: context.road),
              roadPosition.distanceFromRoute <= 8 else { return nil }
        return value
    }

    nonisolated static func priority(for category: MapPOICategory) -> Int {
        switch category {
        case .fuel, .charging: 700
        case .parking: 650
        case .transit: 500
        case .lodging: 450
        case .health: 400
        case .attractions: 350
        case .food: 300
        case .shopping: 250
        }
    }

    nonisolated static func showsRoadDetail(_ category: MapSafetyPOICategory, zoom: Double,
                                           navigating: Bool) -> Bool {
        guard !navigating else { return false } // Navigation uses matched route alerts exclusively.
        return zoom >= (category == .speedCameras ? 12 : 17)
    }
}
