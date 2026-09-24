import Foundation
import Security

struct TrafficFlow {
    let currentSpeedKph: Int
    let freeFlowSpeedKph: Int
    let confidence: Double?
    let roadClosure: Bool
    let coordinates: [Coordinate]
    let updatedAt: Date

    var overlayColorHex: UInt32 {
        if roadClosure { return RouteColorPalette.closure }
        let ratio = Double(currentSpeedKph) / Double(max(1, freeFlowSpeedKph))
        if ratio >= 0.85 { return RouteColorPalette.trafficFree }
        if ratio >= 0.65 { return RouteColorPalette.trafficModerate }
        if ratio >= 0.4 { return RouteColorPalette.trafficSlow }
        if currentSpeedKph <= 5 || ratio <= 0.15 { return RouteColorPalette.trafficStationary }
        return RouteColorPalette.trafficHeavy
    }
}

enum TrafficIncidentCategory: String, Equatable {
    case unknown, accident, fog, dangerousConditions, rain, ice, jam, laneClosed
    case roadClosed, roadWorks, wind, flooding, detour, cluster

    init(tomTomValue: Int?) {
        switch tomTomValue {
        case 1: self = .accident
        case 2: self = .fog
        case 3: self = .dangerousConditions
        case 4: self = .rain
        case 5: self = .ice
        case 6: self = .jam
        case 7: self = .laneClosed
        case 8: self = .roadClosed
        case 9: self = .roadWorks
        case 10: self = .wind
        case 11: self = .flooding
        case 12: self = .detour
        case 13: self = .cluster
        default: self = .unknown
        }
    }
}

enum TrafficIncidentSeverity: String, Equatable {
    case unknown, minor, moderate, major, indefinite

    init(tomTomValue: Int?) {
        switch tomTomValue {
        case 1: self = .minor
        case 2: self = .moderate
        case 3: self = .major
        case 4: self = .indefinite
        default: self = .unknown
        }
    }
}

struct TrafficIncident: Identifiable {
    let id: String
    let description: String
    let coordinate: Coordinate
    let delaySeconds: Int?
    let category: TrafficIncidentCategory
    let severity: TrafficIncidentSeverity

    var isRoadClosure: Bool { category == .roadClosed }
}

struct TrafficSnapshot {
    let flow: TrafficFlow?
    let incidents: [TrafficIncident]
    let updatedAt: Date
    let partialError: String?
    let incidentDataAvailable: Bool
}

protocol TrafficProvider {
    func snapshot(near: Coordinate, route: NavigationRoute?, progress: RouteProgress?) async throws -> TrafficSnapshot
}

enum TrafficError: LocalizedError {
    case invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Nieprawidłowa odpowiedź serwera ruchu."
        case .http(let code): "Serwer ruchu zwrócił HTTP \(code)."
        }
    }
}

struct TomTomTrafficProvider: TrafficProvider {
    let apiKey: String

    func snapshot(near point: Coordinate, route: NavigationRoute?, progress: RouteProgress?) async throws -> TrafficSnapshot {
        async let flowRequest = fetchFlow(near: point)
        async let incidentRequest = fetchIncidents(near: point, route: route, progress: progress)
        let flow: Result<TrafficFlow?, Error>
        do { flow = .success(try await flowRequest) }
        catch { flow = .failure(error) }
        let incidents: Result<[TrafficIncident], Error>
        do { incidents = .success(try await incidentRequest) }
        catch { incidents = .failure(error) }
        if case .failure(let error) = flow, case .failure = incidents { throw error }
        let flowValue = try? flow.get()
        let incidentValue = (try? incidents.get()) ?? []
        let partialError: String? = {
            if case .failure = flow { return "Brak pomiaru przepływu." }
            if case .failure = incidents { return "Nie udało się pobrać zgłoszeń drogowych." }
            return nil
        }()
        return TrafficSnapshot(flow: flowValue ?? nil, incidents: incidentValue, updatedAt: Date(),
                               partialError: partialError,
                               incidentDataAvailable: { if case .success = incidents { true } else { false } }())
    }

    private func fetchFlow(near point: Coordinate) async throws -> TrafficFlow? {
        var url = URLComponents(string: "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/16/json")!
        url.queryItems = [URLQueryItem(name: "key", value: apiKey),
                          URLQueryItem(name: "point", value: "\(point.latitude),\(point.longitude)"),
                          URLQueryItem(name: "unit", value: "kmph")]
        let data = try await load(url.url!)
        let response = try JSONDecoder().decode(FlowResponse.self, from: data).flowSegmentData
        guard response.currentSpeed >= 0, response.freeFlowSpeed > 0 else { return nil }
        let coordinates = response.coordinates?.coordinate.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        } ?? []
        if coordinates.count > 1,
           MapMatcher.project(point, onto: coordinates)?.distanceFromRoute ?? .infinity > 80 {
            return nil
        }
        return TrafficFlow(currentSpeedKph: response.currentSpeed, freeFlowSpeedKph: response.freeFlowSpeed,
                           confidence: response.confidence, roadClosure: response.roadClosure ?? false,
                           coordinates: coordinates, updatedAt: Date())
    }

    private func fetchIncidents(near point: Coordinate, route: NavigationRoute?, progress: RouteProgress?) async throws -> [TrafficIncident] {
        let latDelta = 0.045
        let lonDelta = 0.045 / max(0.25, cos(point.latitude * .pi / 180))
        var url = URLComponents(string: "https://api.tomtom.com/traffic/services/5/incidentDetails")!
        url.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "bbox", value: "\(point.longitude - lonDelta),\(point.latitude - latDelta),\(point.longitude + lonDelta),\(point.latitude + latDelta)"),
            URLQueryItem(name: "fields", value: "{incidents{type,geometry{type,coordinates},properties{id,events{description},delay,iconCategory,magnitudeOfDelay}}}"),
            URLQueryItem(name: "language", value: "pl-PL"),
            URLQueryItem(name: "timeValidityFilter", value: "present")
        ]
        let data = try await load(url.url!)
        let features = try JSONDecoder().decode(IncidentResponse.self, from: data).incidents
        return features.compactMap { feature in
            let points = feature.geometry.points
            guard !points.isEmpty else { return nil }
            let coordinate: Coordinate
            if let route {
                guard let closest = points.compactMap({ coordinate -> (Coordinate, RouteProjection)? in
                    guard let projection = MapMatcher.project(coordinate, onto: route.coordinates) else { return nil }
                    return (coordinate, projection)
                }).min(by: { $0.1.distanceFromRoute < $1.1.distanceFromRoute }),
                closest.1.distanceFromRoute < 120 else { return nil }
                if let progress, closest.1.alongRoute + 50 < progress.traveledDistance || closest.1.alongRoute > progress.traveledDistance + 8_000 { return nil }
                coordinate = closest.0
            } else {
                coordinate = points.min(by: { $0.distance(to: point) < $1.distance(to: point) })!
            }
            let description = feature.properties.events?.first?.description ?? "Utrudnienie drogowe"
            return TrafficIncident(id: feature.properties.id ?? UUID().uuidString,
                                   description: description, coordinate: coordinate,
                                   delaySeconds: feature.properties.delay,
                                   category: TrafficIncidentCategory(tomTomValue: feature.properties.iconCategory),
                                   severity: TrafficIncidentSeverity(tomTomValue: feature.properties.magnitudeOfDelay))
        }
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TrafficError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw TrafficError.http(response.statusCode) }
        return data
    }

    private struct FlowResponse: Decodable { let flowSegmentData: FlowData }
    private struct FlowData: Decodable {
        let currentSpeed: Int
        let freeFlowSpeed: Int
        let confidence: Double?
        let roadClosure: Bool?
        let coordinates: FlowCoordinates?
    }
    private struct FlowCoordinates: Decodable { let coordinate: [FlowPoint] }
    private struct FlowPoint: Decodable { let latitude: Double; let longitude: Double }
    private struct IncidentResponse: Decodable { let incidents: [IncidentFeature] }
    private struct IncidentFeature: Decodable { let geometry: IncidentGeometry; let properties: IncidentProperties }
    private struct IncidentGeometry: Decodable {
        let type: String
        let coordinates: JSONCoordinates
        var points: [Coordinate] { coordinates.values.points }
    }
    private struct IncidentProperties: Decodable {
        let id: String?
        let events: [IncidentEvent]?
        let delay: Int?
        let iconCategory: Int?
        let magnitudeOfDelay: Int?
    }
    private struct IncidentEvent: Decodable { let description: String? }
    private struct JSONCoordinates: Decodable {
        let values: Value
        init(from decoder: Decoder) throws { values = try Value(from: decoder) }
        indirect enum Value: Decodable {
            case number(Double), array([Value])
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) { self = .number(number) }
                else { self = .array(try container.decode([Value].self)) }
            }
            var points: [Coordinate] {
                guard case .array(let values) = self else { return [] }
                if values.count >= 2, case .number(let longitude) = values[0],
                   case .number(let latitude) = values[1] {
                    return [Coordinate(latitude: latitude, longitude: longitude)]
                }
                return values.flatMap(\.points)
            }
        }
    }
}

/// Stored locally. A client-side API key is visible to the configured provider, not a server secret.
enum TrafficCredential {
    private static let service = "NaviAstra.TomTomTraffic"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func save(_ key: String?) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let item: [String: Any] = query.merging([kSecValueData as String: data]) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
