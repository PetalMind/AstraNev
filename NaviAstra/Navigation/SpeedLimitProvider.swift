import Foundation

protocol SpeedLimitProvider {
    func limit(at coordinate: Coordinate, heading: Double?) async throws -> SpeedLimitReading?
}

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
        guard endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        var location: [String: Any] = ["lat": coordinate.latitude, "lon": coordinate.longitude]
        if let heading, heading >= 0 { location["heading"] = heading; location["heading_tolerance"] = 45 }
        var request = URLRequest(url: endpoint.appendingPathComponent("locate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["locations": [location], "costing": "auto", "verbose": true])
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint, priority: true)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        let locations = try JSONDecoder().decode([LocatedPoint].self, from: data)
        guard let edge = locations.first?.edges.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) else { return nil }
        // Current servers store posted limits in edge_info; older tiles used edge.
        // Never substitute edge.speed, which is a routing estimate.
        guard edge.edgeInfo?.conditionalSpeedLimits?.isEmpty != false,
              let limit = edge.edgeInfo != nil ? edge.edgeInfo?.speedLimit : edge.edge?.speedLimit,
              limit > 0, limit < 200 else { return nil }
        return SpeedLimitReading(speedKph: limit,
                                 road: edge.edgeInfo?.shape.map(Polyline6.decode) ?? [])
    }

    private struct LocatedPoint: Decodable { let edges: [LocatedEdge] }
    private struct LocatedEdge: Decodable {
        let distance: Double?
        let edge: Edge?
        let edgeInfo: EdgeInfo?
        enum CodingKeys: String, CodingKey {
            case distance, edge
            case edgeInfo = "edge_info"
        }
    }
    private struct EdgeInfo: Decodable {
        let speedLimit: Int?
        let shape: String?
        let conditionalSpeedLimits: [String: Int]?
        enum CodingKeys: String, CodingKey {
            case shape
            case speedLimit = "speed_limit"
            case conditionalSpeedLimits = "conditional_speed_limits"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Valhalla also sends the string "unlimited" on unrestricted roads.
            speedLimit = try? container.decode(Int.self, forKey: .speedLimit)
            shape = try container.decodeIfPresent(String.self, forKey: .shape)
            conditionalSpeedLimits = try container.decodeIfPresent([String: Int].self, forKey: .conditionalSpeedLimits)
        }
    }
    private struct Edge: Decodable {
        let speedLimit: Int?
        enum CodingKeys: String, CodingKey { case speedLimit = "speed_limit" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            speedLimit = try? container.decode(Int.self, forKey: .speedLimit)
        }
    }
}
