import Foundation

enum RoutingError: LocalizedError {
    case invalidEndpoint, server(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Nieprawidłowy adres serwera tras."
        case .server(let code): "Serwer tras zwrócił błąd HTTP \(code)."
        case .invalidResponse: "Serwer tras zwrócił nieprawidłową trasę."
        }
    }
}

struct ValhallaRouteProvider: AdvancedRouteProvider {
    let endpoint: URL

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, through: [], mode: mode,
                                  preferences: RoutingPreferences(), avoiding: [])
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        guard endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        guard mode != .transit && mode != .parkRide else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("route"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "locations": ([from] + through + [to]).map { ["lat": $0.latitude, "lon": $0.longitude] },
            "costing": mode.valhallaCosting,
            "units": "kilometers",
            "directions_options": ["language": "pl-PL"],
            "alternates": 2
        ]
        if !avoiding.isEmpty {
            payload["avoid_locations"] = avoiding.map { ["lat": $0.latitude, "lon": $0.longitude] }
        }
        if mode == .car {
            var carOptions: [String: Any] = [:]
            if preferences.avoidTolls { carOptions["use_tolls"] = 0.0 }
            if preferences.avoidHighways { carOptions["use_highways"] = 0.0 }
            if preferences.avoidFerries { carOptions["use_ferry"] = 0.0 }
            if preferences.avoidUnpaved { carOptions["exclude_unpaved"] = true }
            if !carOptions.isEmpty { payload["costing_options"] = ["auto": carOptions] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let trips = [result.trip] + (result.alternates ?? []).map(\.trip)
        let routes = trips.compactMap { trip -> NavigationRoute? in
            let legs = trip.legs
            var coordinates: [Coordinate] = []
            var maneuvers: [Maneuver] = []
            for leg in legs {
                let legCoordinates = Polyline6.decode(leg.shape)
                guard !legCoordinates.isEmpty else { return nil }
                let offset = max(0, coordinates.count - (coordinates.isEmpty ? 0 : 1))
                coordinates.append(contentsOf: coordinates.isEmpty ? legCoordinates : Array(legCoordinates.dropFirst()))
                maneuvers += leg.maneuvers.map {
                    Maneuver(shapeIndex: min(coordinates.count - 1, offset + $0.beginShapeIndex),
                             instruction: $0.instruction, type: $0.type,
                             streetNames: $0.streetNames,
                             lanes: $0.lanes.enumerated().map { index, lane in
                                 TurnLaneGuidance(id: index, indications: lane.indications,
                                                  valid: lane.valid ?? lane.active ?? false)
                             },
                             exitNumber: $0.sign?.exitNumber,
                             exitRoad: $0.sign?.exitRoad,
                             exitToward: $0.sign?.exitToward)
                }
            }
            guard coordinates.count > 1 else { return nil }
            return NavigationRoute(coordinates: coordinates, distance: trip.summary.length * 1000,
                                   expectedTravelTime: trip.summary.time, maneuvers: maneuvers, journey: nil)
        }
        guard !routes.isEmpty else { throw RoutingError.invalidResponse }
        return routes
    }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] {
        guard endpoint.scheme == "https", mode == .car || mode == .walking || mode == .bicycle,
              waypoints.count >= 2 else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("optimized_route"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "locations": ([from] + waypoints.map(\.coordinate) + [to]).map {
                ["lat": $0.latitude, "lon": $0.longitude]
            },
            "costing": mode.valhallaCosting,
            "units": "kilometers"
        ]
        if mode == .car {
            var carOptions: [String: Any] = [:]
            if preferences.avoidTolls { carOptions["use_tolls"] = 0.0 }
            if preferences.avoidHighways { carOptions["use_highways"] = 0.0 }
            if preferences.avoidFerries { carOptions["use_ferry"] = 0.0 }
            if preferences.avoidUnpaved { carOptions["exclude_unpaved"] = true }
            if !carOptions.isEmpty { payload["costing_options"] = ["auto": carOptions] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoutingError.invalidResponse
        }
        let optimized = object["optimized_route"] as? [String: Any] ?? object
        guard let locations = (optimized["locations"] as? [[String: Any]]) ??
                (object["locations"] as? [[String: Any]]) else { throw RoutingError.invalidResponse }
        let indexes = locations.compactMap { $0["original_index"] as? Int }
        let ordered = indexes.filter { $0 > 0 && $0 <= waypoints.count }.map { $0 - 1 }
        guard ordered.count == waypoints.count, Set(ordered).count == waypoints.count else {
            throw RoutingError.invalidResponse
        }
        return ordered
    }

    private struct Response: Decodable {
        let trip: Trip
        let alternates: [Alternate]?
    }
    private struct Alternate: Decodable { let trip: Trip }
    private struct Trip: Decodable { let summary: Summary; let legs: [Leg] }
    private struct Summary: Decodable { let length: Double; let time: Double }
    private struct Leg: Decodable { let shape: String; let maneuvers: [Turn] }
    private struct Turn: Decodable {
        let type: Int
        let instruction: String
        let streetNames: [String]
        let beginShapeIndex: Int
        let lanes: [Lane]
        let sign: Sign?

        enum CodingKeys: String, CodingKey {
            case type, instruction, lanes, streetNames = "street_names", turnLanes = "turn_lanes", sign
            case beginShapeIndex = "begin_shape_index"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(Int.self, forKey: .type)
            instruction = try container.decode(String.self, forKey: .instruction)
            streetNames = (try? container.decode([String].self, forKey: .streetNames)) ?? []
            beginShapeIndex = try container.decode(Int.self, forKey: .beginShapeIndex)
            lanes = (try? container.decode([Lane].self, forKey: .lanes))
                ?? (try? container.decode([Lane].self, forKey: .turnLanes)) ?? []
            sign = try? container.decode(Sign.self, forKey: .sign)
        }
    }
    private struct Lane: Decodable {
        let indications: [String]
        let valid: Bool?
        let active: Bool?
        enum CodingKeys: String, CodingKey { case indications, directions, valid, active }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            indications = (try? container.decode([String].self, forKey: .indications))
                ?? (try? container.decode([String].self, forKey: .directions)) ?? []
            valid = try? container.decode(Bool.self, forKey: .valid)
            active = try? container.decode(Bool.self, forKey: .active)
        }
    }
    private struct Sign: Decodable {
        let exitNumber: String?
        let exitRoad: String?
        let exitToward: String?
        enum CodingKeys: String, CodingKey {
            case exitNumberElements = "exit_number_elements"
            case exitBranchElements = "exit_branch_elements"
            case exitTowardElements = "exit_toward_elements"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exitNumber = try? container.decode([SignElement].self, forKey: .exitNumberElements).first?.text
            exitRoad = try? container.decode([SignElement].self, forKey: .exitBranchElements).first?.text
            exitToward = try? container.decode([SignElement].self, forKey: .exitTowardElements).first?.text
        }
    }
    private struct SignElement: Decodable { let text: String }
}

enum Polyline6 {
    static func decode(_ encoded: String) -> [Coordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0, latitude = 0, longitude = 0
        var points: [Coordinate] = []
        func value() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count && shift < 35 {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0 else { return nil }
                result |= (byte & 31) << shift
                if byte < 32 { return result & 1 == 1 ? ~(result >> 1) : result >> 1 }
                shift += 5
            }
            return nil
        }
        while index < bytes.count {
            guard let lat = value(), let lon = value() else { break }
            latitude += lat; longitude += lon
            points.append(Coordinate(latitude: Double(latitude) / 1_000_000, longitude: Double(longitude) / 1_000_000))
        }
        return points
    }
}
