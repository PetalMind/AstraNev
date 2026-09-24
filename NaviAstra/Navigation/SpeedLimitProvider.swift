import Foundation

protocol SpeedLimitProvider {
    func limit(at coordinate: Coordinate, heading: Double?) async throws -> Int?
}

struct ValhallaSpeedLimitProvider: SpeedLimitProvider {
    let endpoint: URL

    func limit(at coordinate: Coordinate, heading: Double?) async throws -> Int? {
        guard endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        var location: [String: Any] = ["lat": coordinate.latitude, "lon": coordinate.longitude]
        if let heading, heading >= 0 { location["heading"] = heading; location["heading_tolerance"] = 45 }
        var request = URLRequest(url: endpoint.appendingPathComponent("locate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["locations": [location], "costing": "auto", "verbose": true])
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        let locations = try JSONDecoder().decode([LocatedPoint].self, from: data)
        guard let edge = locations.first?.edges.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) else { return nil }
        guard let limit = edge.edge?.speedLimit, limit > 0, limit < 200 else { return nil }
        return limit
    }

    private struct LocatedPoint: Decodable { let edges: [LocatedEdge] }
    private struct LocatedEdge: Decodable {
        let distance: Double?
        let edge: Edge?
    }
    private struct Edge: Decodable {
        let speedLimit: Int?
        enum CodingKeys: String, CodingKey { case speedLimit = "speed_limit" }
    }
}
