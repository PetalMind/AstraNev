import Foundation

protocol SpeedLimitProvider {
    func limit(at coordinate: Coordinate, heading: Double?) async throws -> SpeedLimitReading?
    func speedLimitWays(aheadOn geometry: RouteProgressGeometry, from distance: Double) async throws -> [RouteSpeedWay]
}

extension SpeedLimitProvider {
    func speedLimitWays(aheadOn geometry: RouteProgressGeometry, from distance: Double) async throws -> [RouteSpeedWay] { [] }
}

/// A fix on a specific, confidently identified stretch of the active route.
struct SpeedLimitRoadPosition {
    let routeID: UUID
    let maneuverIndex: Int?
    let segment: Int
    let roadName: String?
    let wayID: Int64?
    let passedRuleID: String?
    let progress: Double
    let fix: NavigationLocation

    init?(state: NavigationState, fix: NavigationLocation) {
        guard state.deviationState == .onRoute, !state.weakGPS, let route = state.route,
              (0...20).contains(fix.accuracy), fix.speed >= 1.5, (0..<360).contains(fix.course),
              fix.courseAccuracy < 0 || fix.courseAccuracy <= 30,
              let road = MapDisplayPriorityEngine.matchedRoad(in: state),
              road.match.locationTimestamp == fix.timestamp,
              let matching = state.mapMatchingResult, !matching.ambiguous else { return nil }
        let delta = abs(fix.course - matching.roadBearing)
        guard min(delta, 360 - delta) <= 30 else { return nil }
        self.fix = fix
        routeID = route.id
        segment = road.match.match.projection.segment
        maneuverIndex = route.maneuvers.last(where: { $0.shapeIndex <= road.match.match.projection.segment })?.shapeIndex
        roadName = matching.roadName
        wayID = road.wayID
        passedRuleID = MapDisplayPriorityEngine.lastPassedSpeedRule(in: state)?.id
        progress = road.match.match.projection.alongRoute
    }

    func continues(from prior: Self) -> Bool {
        guard routeID == prior.routeID, maneuverIndex == prior.maneuverIndex,
              roadName == prior.roadName, passedRuleID == prior.passedRuleID,
              (0...25).contains(fix.timestamp.timeIntervalSince(prior.fix.timestamp)),
              (-5...500).contains(progress - prior.progress),
              fix.coordinate.distance(to: prior.fix.coordinate) <= 500 else { return false }
        if let before = prior.wayID, let now = wayID { return before == now }
        return roadName?.isEmpty == false || segment == prior.segment
    }
}

enum SpeedLimitLookupError: Error { case unresolvedRule }

struct SpeedLimitReading {
    let speedKph: Int
    let road: [Coordinate]

    func matches(_ location: NavigationLocation) -> Bool {
        guard road.count > 1,
              let projection = MapMatcher.project(location.coordinate, onto: road),
              projection.distanceFromRoute <= max(20, min(45, location.accuracy)),
              road.indices.contains(projection.segment + 1) else { return false }
        guard location.course >= 0 else { return true }
        let start = road[projection.segment], end = road[projection.segment + 1]
        let bearing = (atan2((end.longitude - start.longitude) * cos(start.latitude * .pi / 180),
                            end.latitude - start.latitude) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        let delta = abs(location.course - bearing)
        let angle = min(delta, 360 - delta)
        return min(angle, 180 - angle) <= 45
    }
}

struct ValhallaSpeedLimitProvider: SpeedLimitProvider {
    let endpoint: URL

    func limit(at coordinate: Coordinate, heading: Double?) async throws -> SpeedLimitReading? {
        var location: [String: Any] = ["lat": coordinate.latitude, "lon": coordinate.longitude]
        if let heading, heading >= 0 { location["heading"] = heading; location["heading_tolerance"] = 45 }
        let data = try await locate([location], priority: true)
        let locations = try JSONDecoder().decode([LocatedPoint].self, from: data)
        guard let edge = locations.first?.edges?.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) else { return nil }
        // Current servers store posted limits in edge_info; older tiles used edge.
        // Never substitute edge.speed, which is a routing estimate.
        if edge.edgeInfo?.conditionalSpeedLimits?.isEmpty == false ||
            edge.edgeInfo?.unlimited == true || (edge.edgeInfo == nil && edge.edge?.unlimited == true) {
            throw SpeedLimitLookupError.unresolvedRule
        }
        guard let limit = edge.edgeInfo != nil ? edge.edgeInfo?.speedLimit : edge.edge?.speedLimit,
              limit > 0, limit < 200 else { return nil }
        return SpeedLimitReading(speedKph: limit,
                                 road: edge.edgeInfo?.shape.map(Polyline6.decode) ?? [])
    }

    func speedLimitWays(aheadOn geometry: RouteProgressGeometry, from distance: Double) async throws -> [RouteSpeedWay] {
#if os(iOS)
        guard !OfflineRoutingStore.shared.preferOffline, !OfflineRoutingStore.shared.networkUnavailable else { return [] }
#endif
        guard distance.isFinite, distance >= 0 else { return [] }
        // A single optional request, denser close to the driver. Only returned
        // edge geometries constitute evidence; gaps between samples stay unknown.
        let offsets: [Double] = [0, 25, 50, 100, 150, 225, 300, 425, 600, 850, 1_200, 1_800]
        var locations: [[String: Any]] = []
        var headings: [Double] = []
        for offset in offsets {
            let at = distance + offset
            guard at < geometry.length, let coordinate = geometry.coordinate(at: at),
                  let heading = geometry.bearing(at: at, lookAhead: 15) else { continue }
            locations.append(["lat": coordinate.latitude, "lon": coordinate.longitude,
                              "heading": Int(heading.rounded()) % 360, "heading_tolerance": 25, "radius": 10])
            headings.append(heading)
        }
        guard !locations.isEmpty else { return [] }
        let data = try await locate(locations, priority: false)
        return try await Self.speedLimitWays(from: data, headings: headings)
    }

    private func locate(_ locations: [[String: Any]], priority: Bool) async throws -> Data {
        guard endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("locate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        if priority { request.networkServiceType = .responsiveData }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra", forHTTPHeaderField: "X-Client-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["locations": locations, "costing": "auto", "verbose": true])
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint, priority: priority)
        let (data, response) = try await RoadRoutingContext.data(for: request)
        try ValhallaServices.validate(data: data, response: response)
        return data
    }

    @concurrent static func speedLimitWays(from data: Data, headings: [Double]) async throws -> [RouteSpeedWay] {
        let locations = try JSONDecoder().decode([LocatedPoint].self, from: data)
        guard locations.count == headings.count else { throw RoutingError.invalidResponse }
        var seen = Set<String>()
        var ways: [RouteSpeedWay] = []
        for (point, heading) in zip(locations, headings) {
            try Task.checkCancellation()
            guard let edges = point.edges else { continue }
            let candidates = edges.filter { candidate in
                guard let angle = candidate.heading, (0...360).contains(angle),
                      let distance = candidate.distance, (0...10).contains(distance),
                      candidate.edge?.access?.car == true else { return false }
                let delta = abs(heading - angle)
                return min(delta, 360 - delta) <= 25
            }
            guard let best = candidates.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }),
                  let distance = best.distance, let info = best.edgeInfo, let shape = info.shape,
                  let forward = best.edge?.forward,
                  !candidates.contains(where: {
                      ($0.edgeInfo?.shape != shape || $0.edgeInfo?.wayID != info.wayID ||
                       $0.forwardRule != best.forwardRule) && ($0.distance ?? .infinity) <= distance + 3
                  }) else { continue }
            let key = (forward ? "+" : "-") + shape
            guard seen.insert(key).inserted else { continue }
            var coordinates = Polyline6.decode(shape)
            guard coordinates.count >= 2, coordinates.allSatisfy(\.isValidValhallaCoordinate) else { continue }
            if !forward { coordinates.reverse() }
            ways.append(RouteSpeedWay(coordinates: coordinates, forward: best.forwardRule, backward: .unknown))
        }
        return ways
    }

    private nonisolated struct LocatedPoint: Decodable { let edges: [LocatedEdge]? }
    private nonisolated struct LocatedEdge: Decodable {
        let distance: Double?
        let heading: Double?
        let edge: Edge?
        let edgeInfo: EdgeInfo?
        enum CodingKeys: String, CodingKey {
            case distance, heading, edge
            case edgeInfo = "edge_info"
        }
        var forwardRule: RouteSpeedRule {
            // The generic edge_info limit can coexist with a different directed
            // maxspeed on the OSM way. The directed speed may invalidate a value,
            // but never supplies its replacement. A generic "unlimited" alone
            // cannot distinguish a directional cap from a modeled travel speed.
            guard let info = edgeInfo, info.conditionalSpeedLimits?.isEmpty != false,
                  let limit = info.speedLimit, (1..<200).contains(limit), let speeds = edge?.speeds,
                  speeds.type == "classified" || (speeds.type == "tagged" && speeds.defaultSpeed == limit)
            else { return .unknown }
            return .posted(limit)
        }
    }
    private nonisolated struct EdgeInfo: Decodable {
        let speedLimit: Int?
        let unlimited: Bool
        let shape: String?
        let wayID: UInt64?
        let conditionalSpeedLimits: [String: Int]?
        enum CodingKeys: String, CodingKey {
            case shape
            case speedLimit = "speed_limit"
            case wayID = "way_id"
            case conditionalSpeedLimits = "conditional_speed_limits"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Valhalla also sends the string "unlimited" on unrestricted roads.
            let value = try? container.decode(Int.self, forKey: .speedLimit)
            speedLimit = value
            unlimited = (try? container.decode(String.self, forKey: .speedLimit)) == "unlimited" || value == 255
            shape = try container.decodeIfPresent(String.self, forKey: .shape)
            wayID = try? container.decode(UInt64.self, forKey: .wayID)
            conditionalSpeedLimits = try container.decodeIfPresent([String: Int].self, forKey: .conditionalSpeedLimits)
        }
    }
    private nonisolated struct Edge: Decodable {
        nonisolated struct Access: Decodable { let car: Bool? }
        nonisolated struct Speeds: Decodable {
            let type: String?
            let defaultSpeed: Int?
            enum CodingKeys: String, CodingKey { case type, defaultSpeed = "default" }
        }
        let forward: Bool?
        let access: Access?
        let speeds: Speeds?
        let speedLimit: Int?
        let unlimited: Bool
        enum CodingKeys: String, CodingKey { case speedLimit = "speed_limit", forward, access, speeds }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            forward = try? container.decode(Bool.self, forKey: .forward)
            access = try? container.decode(Access.self, forKey: .access)
            speeds = try? container.decode(Speeds.self, forKey: .speeds)
            let value = try? container.decode(Int.self, forKey: .speedLimit)
            speedLimit = value
            unlimited = (try? container.decode(String.self, forKey: .speedLimit)) == "unlimited" || value == 255
        }
    }
}
