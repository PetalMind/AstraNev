import Foundation

actor ValhallaRequestGate {
    static let shared = ValhallaRequestGate()
    // The public OpenStreetMap.de service documents a one-request-per-second limit.
    private let publicServerHost = "valhalla1.openstreetmap.de"
    private let publicServerMinimumInterval: TimeInterval = 1.1
    private var nextRequestDateByHost: [String: Date] = [:]
    private var priorityWaitersByHost: [String: Int] = [:]

    func waitUntilAllowed(for endpoint: URL, priority: Bool = false) async throws {
        let host = endpoint.host?.lowercased() ?? endpoint.absoluteString
        let interval = host == publicServerHost ? publicServerMinimumInterval : 0
        guard interval > 0 else { return }
        if priority { priorityWaitersByHost[host, default: 0] += 1 }
        defer { if priority { priorityWaitersByHost[host, default: 0] -= 1 } }
        while true {
            try RoadRoutingContext.checkCancellation()
            if !priority && priorityWaitersByHost[host, default: 0] > 0 {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let now = Date()
            let nextRequestDate = nextRequestDateByHost[host] ?? .distantPast
            guard nextRequestDate > now else {
                nextRequestDateByHost[host] = now.addingTimeInterval(interval)
                return
            }
            let delay = nextRequestDate.timeIntervalSince(now)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

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

    func walkingCosts(from source: Coordinate, to targets: [Coordinate]) async throws -> [WalkingRouteCost?] {
        guard endpoint.scheme == "https", !targets.isEmpty else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("sources_to_targets"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sources": [["lat": source.latitude, "lon": source.longitude]],
            "targets": targets.map { ["lat": $0.latitude, "lon": $0.longitude] },
            "costing": "pedestrian",
            "units": "kilometers",
            "verbose": false,
            "shape_format": "polyline6"
        ])
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await RoadRoutingContext.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        let result = try JSONDecoder().decode(MatrixResponse.self, from: data)
        let matrix = result.sourcesToTargets
        guard let durations = matrix.durations.first, durations.count == targets.count,
              let distances = matrix.distances.first, distances.count == targets.count else {
            throw RoutingError.invalidResponse
        }
        let shapes = matrix.shapes?.first
        return targets.indices.map { index in
            guard let duration = durations[index], let distanceKilometers = distances[index],
                  duration.isFinite, distanceKilometers.isFinite else { return nil }
            let encodedShape: String?
            if let shapes, shapes.indices.contains(index) { encodedShape = shapes[index] }
            else { encodedShape = nil }
            let coordinates = encodedShape.flatMap { shape in
                let points = Polyline6.decode(shape)
                return points.count > 1 ? points : nil
            }
            return WalkingRouteCost(duration: duration, distance: distanceKilometers * 1_000,
                                    coordinates: coordinates)
        }
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        guard endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        guard mode != .transit && mode != .parkRide else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("route"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "locations": ([from] + through + [to]).map { ["lat": $0.latitude, "lon": $0.longitude] },
            "costing": mode.valhallaCosting,
            "units": "kilometers",
            "directions_options": ["language": "pl-PL"],
            "alternates": through.isEmpty ? 2 : 0,
            "turn_lanes": true,
            "roundabout_exits": true,
            "admin_crossings": true
        ]
        if let heading = RoadRoutingContext.heading {
            var locations = payload["locations"] as! [[String: Double]]
            locations[0]["heading"] = heading
            locations[0]["heading_tolerance"] = 45
            payload["locations"] = locations
        }
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
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await RoadRoutingContext.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let trips = [result.trip] + (result.alternates ?? []).map(\.trip)
        let routes = trips.compactMap { trip -> NavigationRoute? in
            let legs = trip.legs
            var coordinates: [Coordinate] = []
            var maneuvers: [Maneuver] = []
            var travelSegments: [RouteTravelSegment] = []
            var legStart = 0.0
            for leg in legs {
                let legCoordinates = Polyline6.decode(leg.shape)
                guard !legCoordinates.isEmpty else { return nil }
                let offset = max(0, coordinates.count - (coordinates.isEmpty ? 0 : 1))
                coordinates.append(contentsOf: coordinates.isEmpty ? legCoordinates : Array(legCoordinates.dropFirst()))
                var cumulative = [0.0]
                for pair in zip(legCoordinates, legCoordinates.dropFirst()) {
                    cumulative.append(cumulative.last! + pair.0.distance(to: pair.1))
                }
                for turn in leg.maneuvers {
                    guard let endIndex = turn.endShapeIndex, let time = turn.time,
                          turn.beginShapeIndex >= 0, endIndex < cumulative.count,
                          endIndex > turn.beginShapeIndex, time.isFinite, time >= 0 else { continue }
                    travelSegments.append(RouteTravelSegment(
                        startDistance: legStart + cumulative[turn.beginShapeIndex],
                        endDistance: legStart + cumulative[endIndex], duration: time))
                }
                legStart += cumulative.last ?? 0
                var roundabouts: [Int: RoundaboutGuidance] = [:]
                for index in leg.maneuvers.indices where leg.maneuvers[index].type == 26 {
                    let next = index + 1
                    guard leg.maneuvers.indices.contains(next), leg.maneuvers[next].type == 27 else { continue }
                    let entry = leg.maneuvers[index]
                    let exit = leg.maneuvers[next]
                    let guidance = RoundaboutGeometry.guidance(
                        coordinates: legCoordinates, entry: entry.beginShapeIndex,
                        exit: exit.beginShapeIndex, exitEnd: exit.endShapeIndex ?? exit.beginShapeIndex,
                        incomingBearing: entry.bearingBefore, outgoingBearing: exit.bearingAfter,
                        exitCount: entry.roundaboutExitCount ?? exit.roundaboutExitCount)
                    roundabouts[index] = guidance
                    roundabouts[next] = guidance
                }
                maneuvers += leg.maneuvers.enumerated().map { index, turn in
                    Maneuver(shapeIndex: min(coordinates.count - 1, offset + turn.beginShapeIndex),
                             instruction: turn.instruction, type: turn.type,
                             streetNames: turn.streetNames,
                             lanes: turn.lanes.enumerated().map { index, lane in
                                 lane.guidance(id: index)
                             },
                             exitNumber: turn.sign?.exitNumber,
                             exitRoad: turn.sign?.exitRoad,
                             exitToward: turn.sign?.exitToward,
                             roundabout: roundabouts[index] ?? (turn.type == 26 || turn.type == 27
                                ? RoundaboutGuidance(exitCount: turn.roundaboutExitCount.flatMap { $0 > 0 ? $0 : nil }) : nil),
                             information: turn.information)
                }
            }
            guard coordinates.count > 1, trip.summary.length.isFinite, trip.summary.length > 0,
                  trip.summary.time.isFinite, trip.summary.time >= 0 else { return nil }
            return NavigationRoute(coordinates: coordinates, distance: trip.summary.length * 1000,
                                   expectedTravelTime: trip.summary.time, maneuvers: maneuvers, journey: nil,
                                   travelSegments: travelSegments,
                                   information: RouteInformation(toll: trip.summary.hasToll,
                                       highway: trip.summary.hasHighway, ferry: trip.summary.hasFerry,
                                       timeRestrictions: trip.summary.hasTimeRestrictions,
                                       warnings: trip.warnings?.compactMap(\.description) ?? [],
                                       countries: Array(Set(legs.flatMap { $0.admins?.compactMap(\.countryText) ?? [] })).sorted(),
                                       destinationSide: trip.locations?.last?.sideOfStreet,
                                       source: RouteInformationSource(endpoint: endpoint, shapes: legs.map(\.shape),
                                                                      costing: mode.valhallaCosting)))
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
        request.timeoutInterval = 25
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
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await RoadRoutingContext.data(for: request)
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
    private struct MatrixResponse: Decodable {
        let sourcesToTargets: WalkingMatrix

        private enum CodingKeys: String, CodingKey { case sourcesToTargets = "sources_to_targets" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let concise = try? container.decode(WalkingMatrix.self, forKey: .sourcesToTargets) {
                sourcesToTargets = concise
            } else {
                let rows = try container.decode([[WalkingMatrixCell]].self, forKey: .sourcesToTargets)
                sourcesToTargets = WalkingMatrix(
                    durations: rows.map { $0.map(\.time) },
                    distances: rows.map { $0.map(\.distance) },
                    shapes: rows.map { $0.map(\.shape) })
            }
        }
    }
    private struct WalkingMatrix: Decodable {
        let durations: [[Double?]]
        let distances: [[Double?]]
        let shapes: [[String?]]?
    }
    private struct WalkingMatrixCell: Decodable {
        let time: Double?
        let distance: Double?
        let shape: String?
    }
    private struct Alternate: Decodable { let trip: Trip }
    private struct Trip: Decodable {
        let summary: Summary
        let legs: [Leg]
        let warnings: [RouteWarning]?
        let locations: [RouteLocation]?
    }
    private struct RouteWarning: Decodable { let description: String? }
    private struct RouteLocation: Decodable {
        let sideOfStreet: String?
        enum CodingKeys: String, CodingKey { case sideOfStreet = "side_of_street" }
    }
    private struct Admin: Decodable {
        let countryText: String?
        enum CodingKeys: String, CodingKey { case countryText = "country_text" }
    }
    private struct Summary: Decodable {
        let length: Double
        let time: Double
        let hasToll: Bool?
        let hasHighway: Bool?
        let hasFerry: Bool?
        let hasTimeRestrictions: Bool?
        enum CodingKeys: String, CodingKey {
            case length, time
            case hasToll = "has_toll", hasHighway = "has_highway", hasFerry = "has_ferry"
            case hasTimeRestrictions = "has_time_restrictions"
        }
    }
    private struct Leg: Decodable { let shape: String; let maneuvers: [Turn]; let admins: [Admin]? }
    private struct Turn: Decodable {
        let type: Int
        let instruction: String
        let streetNames: [String]
        let endShapeIndex: Int?
        let time: Double?
        let beginShapeIndex: Int
        let lanes: [Lane]
        let sign: Sign?
        let roundaboutExitCount: Int?
        let bearingBefore: Double?
        let bearingAfter: Double?
        let information: ManeuverInformation

        enum CodingKeys: String, CodingKey {
            case type, instruction, lanes, streetNames = "street_names", turnLanes = "turn_lanes", sign
            case length, toll, highway, rough, gate, ferry
            case hasTimeRestrictions = "has_time_restrictions", beginStreetNames = "begin_street_names"
            case verbalAlert = "verbal_transition_alert_instruction", verbalBefore = "verbal_pre_transition_instruction"
            case verbalAfter = "verbal_post_transition_instruction", verbalSuccinct = "verbal_succinct_transition_instruction"
            case roundaboutExitCount = "roundabout_exit_count"
            case bearingBefore = "bearing_before", bearingAfter = "bearing_after"
            case beginShapeIndex = "begin_shape_index", endShapeIndex = "end_shape_index", time
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(Int.self, forKey: .type)
            instruction = try container.decode(String.self, forKey: .instruction)
            streetNames = (try? container.decode([String].self, forKey: .streetNames)) ?? []
            beginShapeIndex = try container.decode(Int.self, forKey: .beginShapeIndex)
            endShapeIndex = try container.decodeIfPresent(Int.self, forKey: .endShapeIndex)
            time = try container.decodeIfPresent(Double.self, forKey: .time)
            lanes = (try? container.decode([Lane].self, forKey: .lanes))
                ?? (try? container.decode([Lane].self, forKey: .turnLanes)) ?? []
            sign = try? container.decode(Sign.self, forKey: .sign)
            roundaboutExitCount = try? container.decode(Int.self, forKey: .roundaboutExitCount)
            bearingBefore = try? container.decode(Double.self, forKey: .bearingBefore)
            bearingAfter = try? container.decode(Double.self, forKey: .bearingAfter)
            let length = try? container.decode(Double.self, forKey: .length)
            information = ManeuverInformation(
                distanceMeters: length.flatMap { $0.isFinite && $0 >= 0 ? $0 * 1000 : nil },
                duration: time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                beginStreetNames: (try? container.decode([String].self, forKey: .beginStreetNames)) ?? [],
                exitNumbers: sign?.exitNumbers ?? [], exitRoads: sign?.exitRoads ?? [],
                exitDirections: sign?.exitDirections ?? [], exitNames: sign?.exitNames ?? [],
                toll: try? container.decode(Bool.self, forKey: .toll),
                highway: try? container.decode(Bool.self, forKey: .highway),
                rough: try? container.decode(Bool.self, forKey: .rough),
                gate: try? container.decode(Bool.self, forKey: .gate),
                ferry: try? container.decode(Bool.self, forKey: .ferry),
                timeRestrictions: try? container.decode(Bool.self, forKey: .hasTimeRestrictions),
                verbalAlert: try? container.decode(String.self, forKey: .verbalAlert),
                verbalBefore: try? container.decode(String.self, forKey: .verbalBefore),
                verbalAfter: try? container.decode(String.self, forKey: .verbalAfter),
                verbalSuccinct: try? container.decode(String.self, forKey: .verbalSuccinct))
        }
    }
    private struct Lane: Decodable {
        let indications: [String]
        let valid: Bool?
        let active: Bool?
        let validIndications: [String]
        let activeIndications: [String]

        enum CodingKeys: String, CodingKey { case indications, directions, valid, active }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let mask = try? container.decode(Int.self, forKey: .directions) {
                indications = Self.directionNames(for: mask)
            } else if let values = try? container.decode([String].self, forKey: .directions) {
                indications = values
            } else if let mask = try? container.decode(Int.self, forKey: .indications) {
                indications = Self.directionNames(for: mask)
            } else {
                indications = (try? container.decode([String].self, forKey: .indications)) ?? []
            }

            let validSelection = Self.decodeSelection(from: container, forKey: .valid,
                                                      indications: indications)
            let activeSelection = Self.decodeSelection(from: container, forKey: .active,
                                                       indications: indications)
            valid = validSelection.flag
            active = activeSelection.flag
            validIndications = validSelection.indications
            activeIndications = activeSelection.indications
        }

        func guidance(id: Int) -> TurnLaneGuidance {
            let isActive = active ?? false
            let isValid = valid ?? isActive
            let resolvedValidIndications: [String]
            if !validIndications.isEmpty {
                resolvedValidIndications = validIndications
            } else if valid == true {
                resolvedValidIndications = indications
            } else if valid == nil, isActive {
                resolvedValidIndications = activeIndications.isEmpty ? indications : activeIndications
            } else {
                resolvedValidIndications = []
            }
            return TurnLaneGuidance(
                id: id,
                indications: indications,
                valid: isValid,
                active: isActive,
                validIndications: resolvedValidIndications,
                activeIndications: activeIndications.isEmpty && isActive ? indications : activeIndications)
        }

        private static let directionBits: [(mask: Int, name: String)] = [
            (4, "sharp_left"),
            (8, "left"),
            (16, "slight_left"),
            (2, "through"),
            (32, "slight_right"),
            (64, "right"),
            (128, "sharp_right"),
            (256, "reverse"),
            (512, "merge_left"),
            (1024, "merge_right")
        ]

        private static func directionNames(for mask: Int) -> [String] {
            if mask == 1 { return ["none"] }
            return directionBits.compactMap { mask & $0.mask != 0 ? $0.name : nil }
        }

        private static func decodeSelection(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys,
            indications: [String]
        ) -> (flag: Bool?, indications: [String]) {
            if let mask = try? container.decode(Int.self, forKey: key) {
                return (mask != 0, directionNames(for: mask))
            }
            if let flag = try? container.decode(Bool.self, forKey: key) {
                return (flag, flag ? indications : [])
            }
            if let values = try? container.decode([String].self, forKey: key) {
                return (!values.isEmpty, values)
            }
            return (nil, [])
        }
    }
    private struct Sign: Decodable {
        let exitNumber: String?
        let exitRoad: String?
        let exitToward: String?
        let exitNumbers: [String]
        let exitRoads: [String]
        let exitDirections: [String]
        let exitNames: [String]
        enum CodingKeys: String, CodingKey {
            case exitNameElements = "exit_name_elements"
            case exitNumberElements = "exit_number_elements"
            case exitBranchElements = "exit_branch_elements"
            case exitTowardElements = "exit_toward_elements"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exitNumbers = (try? container.decode([SignElement].self, forKey: .exitNumberElements).map(\.text)) ?? []
            exitRoads = (try? container.decode([SignElement].self, forKey: .exitBranchElements).map(\.text)) ?? []
            exitDirections = (try? container.decode([SignElement].self, forKey: .exitTowardElements).map(\.text)) ?? []
            exitNames = (try? container.decode([SignElement].self, forKey: .exitNameElements).map(\.text)) ?? []
            exitNumber = exitNumbers.first
            exitRoad = exitRoads.first
            exitToward = exitDirections.first
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
                guard (0...63).contains(byte) else { return nil }
                result |= (byte & 31) << shift
                if byte < 32 { return result & 1 == 1 ? ~(result >> 1) : result >> 1 }
                shift += 5
            }
            return nil
        }
        while index < bytes.count {
            guard let lat = value(), let lon = value() else { return [] }
            latitude += lat; longitude += lon
            points.append(Coordinate(latitude: Double(latitude) / 1_000_000, longitude: Double(longitude) / 1_000_000))
        }
        return points
    }
}
