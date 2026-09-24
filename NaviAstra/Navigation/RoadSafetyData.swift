import Foundation

enum SpeedLimitSource: String, Codable, Equatable, Sendable {
    case explicitSign
    case openStreetMap
    case routingProvider
    case trafficZone
    case legalDefault
    case commercialProvider

    var shortTitle: String {
        switch self {
        case .explicitSign: "Znak"
        case .openStreetMap: "OSM"
        case .routingProvider: "Dane trasy"
        case .trafficZone: "Strefa"
        case .legalDefault: "Przepisy"
        case .commercialProvider: "Dostawca map"
        }
    }
}

struct SpeedLimitResult: Equatable, Sendable {
    let speedKph: Int
    let source: SpeedLimitSource
    let confidence: Double
}

enum RoadAlertType: String, Codable, Equatable, Sendable {
    case speedCamera
    case averageSpeedStart
    case averageSpeedEnd
    case redLightCamera
    case speedLimitChange
    case variableSpeedLimit
    case accident
    case roadworks
    case roadClosed
    case congestion
    case railwayCrossing
    case schoolZone
    case dangerousCurve

    var title: String {
        switch self {
        case .speedCamera: "Fotoradar"
        case .averageSpeedStart: "Początek odcinkowego pomiaru"
        case .averageSpeedEnd: "Koniec odcinkowego pomiaru"
        case .redLightCamera: "Rejestracja przejazdu na czerwonym świetle"
        case .speedLimitChange: "Zmiana limitu prędkości"
        case .variableSpeedLimit: "Zmienny limit prędkości"
        case .accident: "Wypadek"
        case .roadworks: "Roboty drogowe"
        case .roadClosed: "Droga zamknięta"
        case .congestion: "Korek"
        case .railwayCrossing: "Przejazd kolejowy"
        case .schoolZone: "Strefa szkolna"
        case .dangerousCurve: "Niebezpieczny zakręt"
        }
    }

    var symbolName: String {
        switch self {
        case .speedCamera, .redLightCamera: "camera.fill"
        case .averageSpeedStart, .averageSpeedEnd: "speedometer"
        case .speedLimitChange: "speedometer"
        case .variableSpeedLimit: "speedometer"
        case .accident: "car.side.front.open.fill"
        case .roadworks: "cone.fill"
        case .roadClosed: "road.lanes.curved.left"
        case .congestion: "car.2.fill"
        case .railwayCrossing: "tram.fill"
        case .schoolZone: "figure.and.child.holdinghands"
        case .dangerousCurve: "arrow.turn.up.right"
        }
    }

    var isEnforcement: Bool {
        switch self {
        case .speedCamera, .averageSpeedStart, .averageSpeedEnd, .redLightCamera: true
        default: false
        }
    }
}

enum RoadAlertSource: String, Codable, Equatable, Sendable {
    case openStreetMap
    case canard
    case here
    case tomtom
}

struct RoadSafetyAlert: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let type: RoadAlertType
    let coordinate: Coordinate
    let source: RoadAlertSource
    var speedLimitKph: Int?
    var distanceAlongRoute: Double?
    var distanceFromRoute: Double?

    var title: String {
        if type == .speedLimitChange, let speedLimitKph {
            return "Limit zmienia się na \(speedLimitKph) km/h"
        }
        return type.title
    }

    func distanceText(from routeDistance: Double) -> String {
        let remaining = max(0, (distanceAlongRoute ?? routeDistance) - routeDistance)
        return remaining >= 1_000
            ? String(format: "%.1f km", remaining / 1_000)
            : "\(Int(remaining.rounded())) m"
    }
}

enum RoadSafetyStatus: Equatable {
    case idle
    case loading
    case available
    case unavailable(String)
}

struct OSMRoadSpeedSegment: Codable, Equatable, Sendable {
    let id: Int64
    let coordinates: [Coordinate]
    let tags: [String: String]
}

nonisolated struct RoadDataSnapshot: Codable, Sendable {
    let speedSegments: [OSMRoadSpeedSegment]
    let alerts: [RoadSafetyAlert]
    let fetchedAt: Date

    func speedLimit(at location: NavigationLocation, date: Date = .now,
                    timeZone: TimeZone = .autoupdatingCurrent) -> SpeedLimitResult? {
        guard let selected = matchedSpeedSegment(at: location),
              let speed = ConditionalSpeedLimitResolver.speedLimit(tags: selected.segment.tags,
                                                                   heading: location.course,
                                                                   segment: selected.segment,
                                                                   projection: selected.projection,
                                                                   date: date,
                                                                   timeZone: timeZone) else { return nil }
        let source: SpeedLimitSource
        if selected.segment.tags["source:maxspeed"] == "sign"
            || selected.segment.tags["maxspeed:type"] == "sign" {
            source = .explicitSign
        } else if ["maxspeed", "maxspeed:forward", "maxspeed:backward"]
            .compactMap({ selected.segment.tags[$0] })
            .contains(where: { SpeedLimitParser.parse($0) != nil })
            || ["maxspeed:conditional", "maxspeed:forward:conditional", "maxspeed:backward:conditional"]
                .contains(where: { selected.segment.tags[$0] != nil }) {
            source = .openStreetMap
        } else if selected.segment.tags["zone:traffic"] != nil {
            source = .trafficZone
        } else if SpeedLimitParser.hasPolishLegalDefault(selected.segment.tags) {
            source = .legalDefault
        } else {
            source = .openStreetMap
        }
        let confidence: Double
        switch source {
        case .explicitSign: confidence = 0.96
        case .legalDefault, .trafficZone: confidence = 0.74
        default: confidence = 0.84
        }
        return SpeedLimitResult(speedKph: speed, source: source, confidence: confidence)
    }

    func shouldSuppressRoutingFallback(at location: NavigationLocation,
                                       date: Date = .now,
                                       timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        guard let selected = matchedSpeedSegment(at: location) else { return false }
        let tags = selected.segment.tags
        guard let forward = ConditionalSpeedLimitResolver.isForward(heading: location.course,
                                                                    segment: selected.segment,
                                                                    projection: selected.projection) else {
            return ConditionalSpeedLimitResolver.hasDirectionalRules(tags)
        }
        let directionalLimitKey = forward ? "maxspeed:forward" : "maxspeed:backward"
        let directionalConditionalKey = forward ? "maxspeed:forward:conditional" : "maxspeed:backward:conditional"
        let baseLimit = tags[directionalLimitKey] ?? tags["maxspeed"]
        let conditionalLimit = tags[directionalConditionalKey] ?? tags["maxspeed:conditional"]
        if conditionalLimit != nil {
            return ConditionalSpeedLimitResolver.speedLimit(tags: tags, heading: location.course,
                                                            segment: selected.segment,
                                                            projection: selected.projection,
                                                            date: date, timeZone: timeZone) == nil
        }
        return ["none", "signals", "walk"].contains(baseLimit?.lowercased() ?? "")
    }

    func matchedAlerts(on route: [Coordinate]) -> [RoadSafetyAlert] {
        guard route.count > 1 else { return [] }
        var unique: [String: RoadSafetyAlert] = [:]
        for alert in alerts {
            guard let projection = MapMatcher.project(alert.coordinate, onto: route),
                  projection.distanceFromRoute <= 90 else { continue }
            var matched = alert
            matched.distanceAlongRoute = projection.alongRoute
            matched.distanceFromRoute = projection.distanceFromRoute
            unique[matched.id] = matched
        }
        let sorted = unique.values.sorted {
            ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity)
        }
        var compacted: [RoadSafetyAlert] = []
        for alert in sorted {
            if compacted.contains(where: {
                $0.type == alert.type && $0.coordinate.distance(to: alert.coordinate) < 20
            }) { continue }
            compacted.append(alert)
        }
        return compacted
    }

    private static func headingPenalty(_ heading: Double, segment: OSMRoadSpeedSegment,
                                       projection: RouteProjection, oneWay: Bool) -> Double {
        guard heading >= 0, heading <= 360,
              segment.coordinates.indices.contains(projection.segment + 1) else { return 0 }
        let start = segment.coordinates[projection.segment]
        let end = segment.coordinates[projection.segment + 1]
        let dx = (end.longitude - start.longitude) * cos(start.latitude * .pi / 180)
        let dy = end.latitude - start.latitude
        let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let difference = abs(heading - bearing)
        let directed = min(difference, 360 - difference)
        let hasDirectionalRules = segment.tags["maxspeed:forward"] != nil
            || segment.tags["maxspeed:backward"] != nil
            || segment.tags["maxspeed:forward:conditional"] != nil
            || segment.tags["maxspeed:backward:conditional"] != nil
        let usable = oneWay || hasDirectionalRules ? directed : min(directed, 180 - directed)
        return min(150, usable * (oneWay ? 1.1 : 0.35))
    }

    private func matchedSpeedSegment(at location: NavigationLocation)
        -> (segment: OSMRoadSpeedSegment, projection: RouteProjection)? {
        let candidates = speedSegments.compactMap { segment -> (OSMRoadSpeedSegment, RouteProjection, Double)? in
            guard segment.coordinates.count > 1,
                  let projection = MapMatcher.project(location.coordinate, onto: segment.coordinates),
                  projection.distanceFromRoute <= max(45, min(120, location.accuracy * 1.5)) else { return nil }
            let headingPenalty = Self.headingPenalty(location.course, segment: segment, projection: projection,
                                                     oneWay: segment.tags["oneway"] == "yes")
            return (segment, projection, projection.distanceFromRoute + headingPenalty)
        }
        guard let selected = candidates.min(by: { $0.2 < $1.2 }) else { return nil }
        return (selected.0, selected.1)
    }
}

protocol RoadDataProvider: Sendable {
    func load(for route: [Coordinate]) async throws -> RoadDataSnapshot
}

struct OpenStreetMapRoadDataProvider: RoadDataProvider {
    private let endpoint: URL

    init(endpoint: URL? = nil) {
        self.endpoint = endpoint
            ?? URL(string: UserDefaults.standard.string(forKey: "overpassServer")
                    ?? "https://overpass-api.de/api/interpreter")!
    }

    func load(for route: [Coordinate]) async throws -> RoadDataSnapshot {
        guard route.count > 1 else { throw RoadDataError.invalidRoute }
        let cacheKey = Self.cacheKey(route)
        if let cached = await RoadDataLocalCache.shared.snapshot(for: cacheKey) { return cached }
        let query = Self.query(route: route)
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra/1.0 (OpenStreetMap road-safety data)", forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RoadDataError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw RoadDataError.server(http.statusCode) }
            data = responseData
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RoadDataError {
            throw error
        } catch {
            throw RoadDataError.unavailable
        }

        let decoded: OverpassResponse
        do { decoded = try JSONDecoder().decode(OverpassResponse.self, from: data) }
        catch { throw RoadDataError.invalidResponse }
        guard decoded.remark == nil else { throw RoadDataError.unavailable }
        try Task.checkCancellation()
        let snapshot = RoadDataSnapshot(speedSegments: Self.speedSegments(from: decoded.elements),
                                        alerts: Self.alerts(from: decoded.elements), fetchedAt: .now)
        await RoadDataLocalCache.shared.store(snapshot, for: cacheKey)
        return snapshot
    }

    private static func cacheKey(_ route: [Coordinate]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for coordinate in sampled(route, maxStep: 800) {
            for value in [coordinate.latitude, coordinate.longitude] {
                let quantized = Int64((value * 100_000).rounded())
                for byte in withUnsafeBytes(of: quantized.littleEndian, Array.init) {
                    hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    private static func query(route: [Coordinate]) -> String {
        let centers = sampled(route, maxStep: 800).map {
            String(format: "%.5f,%.5f", $0.latitude, $0.longitude)
        }.joined(separator: ",")
        let roads = "way(around:120,\(centers))[highway~\"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|track|road)$\"]"
        return """
        [out:json][timeout:25];
        (
          \(roads)[maxspeed];
          \(roads)[\"maxspeed:forward\"];
          \(roads)[\"maxspeed:backward\"];
          \(roads)[\"maxspeed:conditional\"];
          \(roads)[\"maxspeed:forward:conditional\"];
          \(roads)[\"maxspeed:backward:conditional\"];
          \(roads)[\"source:maxspeed\"~\"^PL:\"];
          \(roads)[\"maxspeed:type\"~\"^PL:\"];
          \(roads)[\"zone:traffic\"~\"^PL:\"];
          node(around:120,\(centers))[highway=\"speed_camera\"];
          relation(around:120,\(centers))[type=\"enforcement\"][enforcement~\"^(maxspeed|average_speed|traffic_signals)$\"];
        );
        out geom;
        """
    }

    private static func sampled(_ route: [Coordinate], maxStep: Double) -> [Coordinate] {
        guard let first = route.first else { return [] }
        var result = [first]
        for index in route.indices.dropFirst() {
            let start = route[index - 1]
            let end = route[index]
            let length = start.distance(to: end)
            let pieces = max(1, Int(ceil(length / maxStep)))
            for piece in 1...pieces {
                let fraction = Double(piece) / Double(pieces)
                result.append(Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                                         longitude: start.longitude + (end.longitude - start.longitude) * fraction))
            }
        }
        let cap = 750
        guard result.count > cap else { return result }
        return (0..<cap).map { index in
            result[index * (result.count - 1) / (cap - 1)]
        }
    }

    private static func speedSegments(from elements: [OverpassElement]) -> [OSMRoadSpeedSegment] {
        var unique: [Int64: OSMRoadSpeedSegment] = [:]
        for element in elements where element.type == "way" {
            guard let tags = element.tags,
                  ["maxspeed", "maxspeed:forward", "maxspeed:backward", "maxspeed:conditional",
                   "maxspeed:forward:conditional", "maxspeed:backward:conditional"]
                    .contains(where: { tags[$0] != nil })
                    || SpeedLimitParser.hasPolishLegalDefault(tags),
                  let points = element.geometry, points.count > 1 else { continue }
            unique[element.id] = OSMRoadSpeedSegment(
                id: element.id,
                coordinates: points.map { Coordinate(latitude: $0.lat, longitude: $0.lon) },
                tags: tags)
        }
        return Array(unique.values)
    }

    private static func alerts(from elements: [OverpassElement]) -> [RoadSafetyAlert] {
        var unique: [String: RoadSafetyAlert] = [:]
        for element in elements {
            guard element.type == "node", let latitude = element.lat, let longitude = element.lon,
                  let tags = element.tags, tags["highway"] == "speed_camera" else { continue }
            let type: RoadAlertType = tags["enforcement"] == "traffic_signals"
                || tags["camera:type"] == "red_light" ? .redLightCamera : .speedCamera
            let alert = RoadSafetyAlert(id: "osm-node-\(element.id)", type: type,
                                        coordinate: Coordinate(latitude: latitude, longitude: longitude),
                                        source: .openStreetMap,
                                        speedLimitKph: SpeedLimitParser.parse(tags["maxspeed"]))
            unique[alert.id] = alert
        }

        for element in elements where element.type == "relation" {
            guard element.tags?["type"] == "enforcement",
                  let enforcement = element.tags?["enforcement"] else { continue }
            let members = element.members ?? []
            if enforcement == "average_speed" {
                let sections = members.filter { $0.role == "section" }
                let from = members.first(where: { $0.role == "from" })?.coordinate
                    ?? sections.first?.geometry?.first?.coordinate
                let to = members.first(where: { $0.role == "to" })?.coordinate
                    ?? sections.last?.geometry?.last?.coordinate
                if let from {
                    let alert = RoadSafetyAlert(id: "osm-relation-\(element.id)-start", type: .averageSpeedStart,
                                                coordinate: from, source: .openStreetMap,
                                                speedLimitKph: SpeedLimitParser.parse(element.tags?["maxspeed"]))
                    unique[alert.id] = alert
                }
                if let to {
                    let alert = RoadSafetyAlert(id: "osm-relation-\(element.id)-end", type: .averageSpeedEnd,
                                                coordinate: to, source: .openStreetMap,
                                                speedLimitKph: SpeedLimitParser.parse(element.tags?["maxspeed"]))
                    unique[alert.id] = alert
                }
            } else if enforcement == "traffic_signals" {
                let coordinates = members.filter { $0.role == "device" }.compactMap(\.coordinate)
                for (index, coordinate) in coordinates.enumerated() {
                    let alert = RoadSafetyAlert(id: "osm-relation-\(element.id)-redlight-\(index)",
                                                type: .redLightCamera, coordinate: coordinate,
                                                source: .openStreetMap)
                    unique[alert.id] = alert
                }
            } else if enforcement == "maxspeed" {
                let coordinates = members.filter { $0.role == "device" }.compactMap(\.coordinate)
                for (index, coordinate) in coordinates.enumerated() {
                    let alert = RoadSafetyAlert(id: "osm-relation-\(element.id)-camera-\(index)",
                                                type: .speedCamera, coordinate: coordinate,
                                                source: .openStreetMap,
                                                speedLimitKph: SpeedLimitParser.parse(element.tags?["maxspeed"]))
                    unique[alert.id] = alert
                }
            }
        }
        return Array(unique.values)
    }
}

private actor RoadDataLocalCache {
    static let shared = RoadDataLocalCache()
    private let expiration: TimeInterval = 86_400

    func snapshot(for key: String) -> RoadDataSnapshot? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(RoadDataSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.fetchedAt) >= 0,
              Date().timeIntervalSince(snapshot.fetchedAt) < expiration else { return nil }
        return snapshot
    }

    func store(_ snapshot: RoadDataSnapshot, for key: String) {
        guard let url = fileURL(for: key),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(for key: String) -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return root.appendingPathComponent("NaviAstra/RoadData", isDirectory: true)
            .appendingPathComponent("osm-\(key).json")
    }
}

enum RoadDataError: LocalizedError {
    case invalidRoute
    case unavailable
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRoute: "Nie ma geometrii trasy do pobrania danych drogowych."
        case .unavailable: "Usługa OpenStreetMap jest chwilowo niedostępna."
        case .invalidResponse: "Usługa OpenStreetMap zwróciła nieprawidłowe dane."
        case .server(let status): "Usługa OpenStreetMap zwróciła błąd HTTP \(status)."
        }
    }
}

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
    let remark: String?
}

private struct OverpassElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let tags: [String: String]?
    let geometry: [OverpassPoint]?
    let members: [OverpassMember]?
}

private struct OverpassPoint: Decodable {
    let lat: Double
    let lon: Double

    var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
}

private struct OverpassMember: Decodable {
    let role: String
    let lat: Double?
    let lon: Double?
    let geometry: [OverpassPoint]?

    var coordinate: Coordinate? {
        if let lat, let lon { return Coordinate(latitude: lat, longitude: lon) }
        return geometry?.first?.coordinate
    }
}

enum SpeedLimitParser {
    static func parse(_ rawValue: String?, tags: [String: String] = [:]) -> Int? {
        guard let rawValue else { return polishLegalDefault(tags) }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("pl:") { return polishDefault(for: String(value.dropFirst(3)), tags: tags) }
        guard let match = value.range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression),
              let number = Double(value[match].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let kmh = value.contains("mph") ? number * 1.609344 : number
        guard kmh >= 5, kmh <= 250 else { return nil }
        return Int(kmh.rounded())
    }

    static func hasPolishLegalDefault(_ tags: [String: String]) -> Bool {
        let contexts = [tags["source:maxspeed"], tags["maxspeed:type"], tags["zone:traffic"]]
            .compactMap { $0 }
        return contexts.contains { $0.lowercased().hasPrefix("pl:") }
            || tags["maxspeed"]?.lowercased().hasPrefix("pl:") == true
    }

    private static func polishLegalDefault(_ tags: [String: String]) -> Int? {
        let context = [tags["source:maxspeed"], tags["maxspeed:type"], tags["zone:traffic"]]
            .compactMap { $0 }.first { $0.lowercased().hasPrefix("pl:") }
        guard let context else { return nil }
        return polishDefault(for: String(context.dropFirst(3)).lowercased(), tags: tags)
    }

    private static func polishDefault(for context: String, tags: [String: String]) -> Int? {
        switch context {
        case "urban": return 50
        case "living_street": return 20
        case "motorway": return 140
        case "rural":
            if tags["highway"] == "motorway" { return 140 }
            switch (isDualCarriageway(tags), hasTwoLanesEachDirection(tags)) {
            case (true, true): return 100
            case (true, false), (false, _): return 90
            case (true, nil), (nil, _): return nil
            }
        case "expressway":
            switch isDualCarriageway(tags) {
            case true: return 120
            case false: return 100
            case nil: return nil
            }
        default: return nil
        }
    }

    private static func isDualCarriageway(_ tags: [String: String]) -> Bool? {
        if tags["dual_carriageway"] == "yes" { return true }
        if tags["dual_carriageway"] == "no" { return false }
        guard ["yes", "-1"].contains(tags["oneway"] ?? ""),
              !["roundabout", "circular"].contains(tags["junction"] ?? ""),
              ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link"]
                .contains(tags["highway"] ?? "") else { return nil }
        return true
    }

    private static func hasTwoLanesEachDirection(_ tags: [String: String]) -> Bool? {
        if let forward = Int(tags["lanes:forward"] ?? ""),
           let backward = Int(tags["lanes:backward"] ?? "") {
            return forward >= 2 && backward >= 2
        }
        guard let lanes = Int(tags["lanes"] ?? "") else { return nil }
        if ["yes", "-1"].contains(tags["oneway"] ?? "") {
            return lanes >= 2
        }
        if tags["dual_carriageway"] == "yes" {
            if lanes >= 4 { return true }
            if lanes <= 2 { return false }
        }
        return nil
    }
}

enum ConditionalSpeedLimitResolver {
    static func speedLimit(tags: [String: String], heading: Double,
                           segment: OSMRoadSpeedSegment, projection: RouteProjection,
                           date: Date, timeZone: TimeZone) -> Int? {
        let forward: Bool
        if let direction = isForward(heading: heading, segment: segment, projection: projection) {
            forward = direction
        } else {
            let forwardBase = tags["maxspeed:forward"] ?? tags["maxspeed"]
            let backwardBase = tags["maxspeed:backward"] ?? tags["maxspeed"]
            let forwardConditional = tags["maxspeed:forward:conditional"] ?? tags["maxspeed:conditional"]
            let backwardConditional = tags["maxspeed:backward:conditional"] ?? tags["maxspeed:conditional"]
            guard forwardBase == backwardBase, forwardConditional == backwardConditional else { return nil }
            forward = true
        }
        let directionalKey = forward ? "maxspeed:forward" : "maxspeed:backward"
        let conditionalKey = forward ? "maxspeed:forward:conditional" : "maxspeed:backward:conditional"
        let baseValue = tags[directionalKey] ?? tags["maxspeed"]
        let conditionalValue = tags[conditionalKey] ?? tags["maxspeed:conditional"]
        guard let conditionalValue else { return SpeedLimitParser.parse(baseValue, tags: tags) }

        let rules = conditionalValue.split(separator: ";", omittingEmptySubsequences: true)
        guard !rules.isEmpty else { return nil }
        var matchedLimit: Int?
        for rawRule in rules {
            let rule = String(rawRule).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let at = rule.firstIndex(of: "@"),
                  let limit = SpeedLimitParser.parse(String(rule[..<at]), tags: tags) else { return nil }
            let conditionText = rule[rule.index(after: at)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard conditionText.first == "(", conditionText.last == ")" else { return nil }
            let condition = String(conditionText.dropFirst().dropLast())
            guard let applies = conditionApplies(condition, date: date, timeZone: timeZone) else { return nil }
            if applies { matchedLimit = limit; break }
        }
        return matchedLimit ?? SpeedLimitParser.parse(baseValue, tags: tags)
    }

    fileprivate static func isForward(heading: Double, segment: OSMRoadSpeedSegment,
                                      projection: RouteProjection) -> Bool? {
        guard heading >= 0, heading <= 360,
              segment.coordinates.indices.contains(projection.segment + 1) else { return nil }
        let start = segment.coordinates[projection.segment]
        let end = segment.coordinates[projection.segment + 1]
        let dx = (end.longitude - start.longitude) * cos(start.latitude * .pi / 180)
        let dy = end.latitude - start.latitude
        let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let difference = abs(heading - bearing)
        return min(difference, 360 - difference) <= 90
    }

    fileprivate static func hasDirectionalRules(_ tags: [String: String]) -> Bool {
        let forwardBase = tags["maxspeed:forward"] ?? tags["maxspeed"]
        let backwardBase = tags["maxspeed:backward"] ?? tags["maxspeed"]
        let forwardConditional = tags["maxspeed:forward:conditional"] ?? tags["maxspeed:conditional"]
        let backwardConditional = tags["maxspeed:backward:conditional"] ?? tags["maxspeed:conditional"]
        return forwardBase != backwardBase || forwardConditional != backwardConditional
    }

    private static func conditionApplies(_ rawCondition: String, date: Date,
                                         timeZone: TimeZone) -> Bool? {
        let condition = rawCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayNames = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        let tokens = condition.split(whereSeparator: \.isWhitespace).map(String.init)
        var selectedDays: Set<Int>?
        var timeRange: (Int, Int)?
        for token in tokens {
            if token.contains(":") {
                guard timeRange == nil, let range = parseTimeRange(token) else { return nil }
                timeRange = range
            } else if token.range(of: #"^(Mo|Tu|We|Th|Fr|Sa|Su)(-(Mo|Tu|We|Th|Fr|Sa|Su))?(,(Mo|Tu|We|Th|Fr|Sa|Su)(-(Mo|Tu|We|Th|Fr|Sa|Su))?)*$"#,
                                  options: .regularExpression) != nil {
                guard selectedDays == nil, let parsed = parseDays(token, dayNames: dayNames) else { return nil }
                selectedDays = parsed
            } else {
                return nil
            }
        }
        guard !tokens.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else { return nil }
        let day = (weekday + 5) % 7 // Calendar: Sunday=1; OSM: Monday=0.
        guard let timeRange else { return selectedDays.map { $0.contains(day) } ?? true }
        let now = hour * 60 + minute
        let appliesToday: Bool
        if timeRange.0 <= timeRange.1 {
            appliesToday = now >= timeRange.0 && now < timeRange.1
            guard appliesToday else { return false }
            return selectedDays.map { $0.contains(day) } ?? true
        }
        if now >= timeRange.0 {
            appliesToday = true
            return appliesToday && (selectedDays.map { $0.contains(day) } ?? true)
        }
        if now < timeRange.1 {
            let previousDay = (day + 6) % 7
            return selectedDays.map { $0.contains(previousDay) } ?? true
        }
        return false
    }

    private static func parseTimeRange(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = parseMinute(String(parts[0])),
              let end = parseMinute(String(parts[1])) else { return nil }
        return (start, end)
    }

    private static func parseMinute(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute),
              hour != 24 || minute == 0 else { return nil }
        return hour * 60 + minute
    }

    private static func parseDays(_ value: String, dayNames: [String]) -> Set<Int>? {
        var days: Set<Int> = []
        for part in value.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard let first = dayNames.firstIndex(of: bounds[0]) else { return nil }
            if bounds.count == 1 { days.insert(first); continue }
            guard bounds.count == 2, let last = dayNames.firstIndex(of: bounds[1]) else { return nil }
            var current = first
            days.insert(current)
            while current != last {
                current = (current + 1) % 7
                days.insert(current)
            }
        }
        return days
    }
}
