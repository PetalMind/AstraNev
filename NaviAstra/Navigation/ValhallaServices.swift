import Foundation

nonisolated struct ValhallaServerStatus: Sendable {
    var version: String?
    var modifiedAt: Date?
    var actions: [String]?
    var liveTraffic: Bool?
    var timeZones: Bool?
    var hasTiles: Bool?
    var changeset: String?
}

nonisolated struct ValhallaContour: Identifiable, Sendable {
    var id = UUID()
    var value: Double
    var rings: [[Coordinate]]
}

struct ValhallaServices {
    let endpoint: URL

    func request(_ action: String, payload: [String: Any]) async throws -> Data {
        guard endpoint.scheme == "https", endpoint.host != nil else { throw RoutingError.invalidEndpoint }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra", forHTTPHeaderField: "X-Client-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await RoadRoutingContext.data(for: request)
        try Self.validate(data: data, response: response)
        return data
    }

    nonisolated static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard !(200...299).contains(http.statusCode) else { return }
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if (reply?["error_code"] as? Int) == 442 {
            throw ValhallaFeatureError.message("Nie znaleziono trasy zgodnej z profilem, ograniczeniami pojazdu lub obszarami omijanymi. Zmień punkty albo ustawienia trasy.")
        }
        if http.statusCode == 429 {
            throw ValhallaFeatureError.message("Serwer tras osiągnął limit zapytań. Odczekaj chwilę i spróbuj ponownie.")
        }
        let reason = reply?["error"] as? String
        throw ValhallaFeatureError.message("Serwer tras: HTTP \(http.statusCode). \(reason ?? "Usługa nie jest dostępna lub odrzuciła zapytanie.")")
    }

    func status() async throws -> ValhallaServerStatus {
        let data: Data
        do { data = try await request("status", payload: ["verbose": true]) }
        catch {
            try Task.checkCancellation()
            data = try await request("status", payload: [:])
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoutingError.invalidResponse
        }
        return ValhallaServerStatus(version: root["version"] as? String,
            modifiedAt: (root["tileset_last_modified"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            actions: root["available_actions"] as? [String], liveTraffic: root["has_live_traffic"] as? Bool,
            timeZones: root["has_timezones"] as? Bool, hasTiles: root["has_tiles"] as? Bool,
            changeset: (root["osm_changeset"] as? NSNumber)?.stringValue)
    }

    func contours(at origin: Coordinate, mode: TransportMode, preferences: RoutingPreferences,
                  value: Int, distance: Bool) async throws -> [ValhallaContour] {
        guard origin.isValidValhallaCoordinate, (1...120).contains(value), mode != .transit && mode != .parkRide else {
            throw RoutingError.invalidResponse
        }
        var payload: [String: Any] = ["locations": [["lat": origin.latitude, "lon": origin.longitude]],
            "contours": [[distance ? "distance" : "time": value]], "polygons": true,
            "denoise": 0.5, "generalize": 25, "units": "kilometers"]
        try preferences.applyValhallaOptions(to: &payload, mode: mode)
        let data = try await request("isochrone", payload: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw RoutingError.invalidResponse }
        var results: [ValhallaContour] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            let rawPolygons: [[[[Double]]]]
            switch geometry["type"] as? String {
            case "Polygon": rawPolygons = (geometry["coordinates"] as? [[[Double]]]).map { [$0] } ?? []
            case "MultiPolygon": rawPolygons = geometry["coordinates"] as? [[[[Double]]]] ?? []
            default: continue
            }
            for polygon in rawPolygons {
                let rings = polygon.map { ring in
                    ring.compactMap { point -> Coordinate? in
                        guard point.count >= 2 else { return nil }
                        let coordinate = Coordinate(latitude: point[1], longitude: point[0])
                        return coordinate.isValidValhallaCoordinate ? coordinate : nil
                    }
                }
                guard !rings.isEmpty, rings.allSatisfy({ $0.count >= 4 }) else { continue }
                results.append(ValhallaContour(value: Double(value), rings: rings))
            }
        }
        guard !results.isEmpty else { throw ValhallaFeatureError.message("Serwer nie zwrócił obszaru dostępności dla tego punktu.") }
        return results
    }

    func heights(_ coordinates: [Coordinate], resample: Bool = true) async throws -> [RouteElevationSample] {
        guard !coordinates.isEmpty, coordinates.allSatisfy(\.isValidValhallaCoordinate) else { throw RoutingError.invalidResponse }
        var payload: [String: Any] = ["shape": coordinates.map { ["lat": $0.latitude, "lon": $0.longitude] },
                                    "range": true, "height_precision": 1]
        if resample && coordinates.count > 1 { payload["resample_distance"] = 50 }
        let data = try await request("height", payload: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["range_height"] as? [[Any]], !rows.isEmpty else { throw RoutingError.invalidResponse }
        return try rows.map { row in
            guard row.count >= 2, let distance = row[0] as? Double, distance.isFinite, distance >= 0 else {
                throw RoutingError.invalidResponse
            }
            let height = (row[1] as? Double).flatMap { $0.isFinite && (-500...9000).contains($0) ? $0 : nil }
            return RouteElevationSample(distanceMeters: distance, heightMeters: height)
        }
    }

    func matchTrace(_ segments: [[Coordinate]], mode: TransportMode,
                    preferences: RoutingPreferences) async throws -> [NavigationRoute] {
        guard !segments.isEmpty, segments.count <= 20, mode != .transit && mode != .parkRide else {
            throw ValhallaFeatureError.message("Wybierz ślad drogowy z maksymalnie 20 częściami.")
        }
        var routes: [NavigationRoute] = []
        for segment in segments {
            try Task.checkCancellation()
            guard segment.count >= 2 else { continue }
            guard segment.allSatisfy(\.isValidValhallaCoordinate) else { throw RoutingError.invalidResponse }
            let points = Self.sample(segment, limit: 1_000)
            var payload: [String: Any] = ["shape": points.map { ["lat": $0.latitude, "lon": $0.longitude] },
                "costing": preferences.advanced.costing(for: mode), "shape_match": "map_snap",
                "units": "kilometers", "directions_options": ["language": "pl-PL"],
                "turn_lanes": true, "trace_options": ["gps_accuracy": 15, "search_radius": 50]]
            try preferences.applyValhallaOptions(to: &payload, mode: mode)
            // A recorded path is analysed as recorded, independently of future route exclusions.
            payload.removeValue(forKey: "exclude_polygons")
            payload.removeValue(forKey: "date_time")
            let data = try await request("trace_route", payload: payload)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let trip = root["trip"] as? [String: Any], let legs = trip["legs"] as? [[String: Any]],
                  !legs.isEmpty else { throw RoutingError.invalidResponse }
            // Keep legs separate: map-matching gaps must never become invented connecting lines.
            for leg in legs {
                guard let summary = leg["summary"] as? [String: Any] else { throw RoutingError.invalidResponse }
                var part = trip
                part["legs"] = [leg]
                part["summary"] = summary
                let encoded = try JSONSerialization.data(withJSONObject: ["trip": part])
                routes += try ValhallaRouteProvider(endpoint: endpoint).decodeRoutes(encoded, mode: mode,
                    costing: preferences.advanced.costing(for: mode))
            }
        }
        guard !routes.isEmpty else { throw ValhallaFeatureError.message("Ślad nie zawiera odcinków możliwych do dopasowania do dróg.") }
        return routes
    }

    static func sample(_ points: [Coordinate], limit: Int) -> [Coordinate] {
        guard points.count > limit, limit > 1 else { return points }
        return (0..<limit).map { index in points[Int(Double(index) * Double(points.count - 1) / Double(limit - 1))] }
    }
}
