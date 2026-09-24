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
    case roadClosed, roadWorks, wind, flooding, detour, cluster, brokenDownVehicle

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

    init(tomTomValue: String?) {
        self = tomTomValue.flatMap(TrafficIncidentCategory.init(rawValue:)) ?? .unknown
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

    init(tomTomValue: String?) {
        switch tomTomValue {
        case "minor": self = .minor
        case "moderate": self = .moderate
        case "major": self = .major
        case "indefinite", "undefined": self = .indefinite
        default: self = .unknown
        }
    }
}

extension TrafficIncidentCategory {
    var mapLabel: String {
        switch self {
        case .unknown: "Zdarzenie drogowe"
        case .accident: "Wypadek"
        case .fog: "Mgła"
        case .dangerousConditions: "Niebezpieczne warunki"
        case .rain: "Intensywny deszcz"
        case .ice: "Oblodzenie"
        case .jam: "Korek"
        case .laneClosed: "Zamknięty pas ruchu"
        case .roadClosed: "Droga zamknięta"
        case .roadWorks: "Roboty drogowe"
        case .wind: "Silny wiatr"
        case .flooding: "Podtopienie"
        case .detour: "Objazd"
        case .cluster: "Zbiorcze utrudnienie"
        case .brokenDownVehicle: "Unieruchomiony pojazd"
        }
    }
}

extension TrafficIncidentSeverity {
    var mapLabel: String {
        switch self {
        case .unknown: "Nieokreślone utrudnienie"
        case .minor: "Niewielkie utrudnienie"
        case .moderate: "Umiarkowane utrudnienie"
        case .major: "Poważne utrudnienie"
        case .indefinite: "Nieokreślona skala utrudnienia"
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
    let geometry: [Coordinate]
    let distanceAlongRoute: Double?

    init(id: String, description: String, coordinate: Coordinate, delaySeconds: Int?,
         category: TrafficIncidentCategory, severity: TrafficIncidentSeverity,
         geometry: [Coordinate] = [], distanceAlongRoute: Double? = nil) {
        self.id = id
        self.description = description
        self.coordinate = coordinate
        self.delaySeconds = delaySeconds
        self.category = category
        self.severity = severity
        self.geometry = geometry
        self.distanceAlongRoute = distanceAlongRoute
    }

    var isRoadClosure: Bool { category == .roadClosed }

    var mapTitle: String { isRoadClosure ? "Droga zamknięta" : description }

    var mapSubtitle: String {
        var details = [category.mapLabel, severity.mapLabel]
        if let delaySeconds, delaySeconds > 0 {
            details.append("Opóźnienie około \(max(1, Int((Double(delaySeconds) / 60).rounded()))) min")
        }
        if description != mapTitle { details.append(description) }
        return details.joined(separator: " · ")
    }
}

struct TrafficSnapshot {
    let flow: TrafficFlow?
    let incidents: [TrafficIncident]
    let updatedAt: Date
    let partialError: String?
    let incidentDataAvailable: Bool
}

struct TrafficBoundingBox: Equatable, Sendable {
    let minLongitude: Double
    let minLatitude: Double
    let maxLongitude: Double
    let maxLatitude: Double

    var queryValue: String {
        "\(minLongitude),\(minLatitude),\(maxLongitude),\(maxLatitude)"
    }

    static func around(_ point: Coordinate, radiusMeters: Double) -> Self {
        let latitudeDelta = radiusMeters / 111_320
        let longitudeDelta = radiusMeters / max(1_000, 111_320 * abs(cos(point.latitude * .pi / 180)))
        return Self(minLongitude: point.longitude - longitudeDelta,
                    minLatitude: point.latitude - latitudeDelta,
                    maxLongitude: point.longitude + longitudeDelta,
                    maxLatitude: point.latitude + latitudeDelta)
    }
}

enum TrafficTileStyle: String {
    case light, dark
}

protocol TrafficProvider {
    func snapshot(near: Coordinate, incidentRadiusMeters: Double) async throws -> TrafficSnapshot
    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident]
    func rasterFlowTileURLTemplate(style: TrafficTileStyle) -> String?
    func rasterIncidentTileURLTemplate(style: TrafficTileStyle) -> String?
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

    func snapshot(near point: Coordinate, incidentRadiusMeters: Double) async throws -> TrafficSnapshot {
        async let flowRequest = fetchFlow(near: point)
        async let incidentRequest = incidents(in: [.around(point, radiusMeters: incidentRadiusMeters)])
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

    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] {
        guard !boxes.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [TrafficIncident].self) { group in
            var nextBox = 0
            for _ in 0..<min(4, boxes.count) {
                let box = boxes[nextBox]
                nextBox += 1
                group.addTask { try await fetchIncidents(in: box) }
            }
            var unique: [String: TrafficIncident] = [:]
            for try await incidents in group {
                for incident in incidents where unique[incident.id] == nil {
                    unique[incident.id] = incident
                }
                if nextBox < boxes.count {
                    let box = boxes[nextBox]
                    nextBox += 1
                    group.addTask { try await fetchIncidents(in: box) }
                }
            }
            return Array(unique.values)
        }
    }

    func rasterFlowTileURLTemplate(style: TrafficTileStyle) -> String? {
        "https://api.tomtom.com/maps/orbis/traffic/flow/raster/tile/{z}/{x}/{y}?apiVersion=2&key=\(apiKey)&style=\(style.rawValue)&tileSize=256"
    }

    func rasterIncidentTileURLTemplate(style: TrafficTileStyle) -> String? {
        "https://api.tomtom.com/maps/orbis/traffic/incidents/raster/tile/{z}/{x}/{y}?apiVersion=2&key=\(apiKey)&style=\(style.rawValue)&tileSize=256"
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

    private func fetchIncidents(in box: TrafficBoundingBox) async throws -> [TrafficIncident] {
        var url = URLComponents(string: "https://api.tomtom.com/maps/orbis/traffic/incidents/details")!
        url.queryItems = [
            URLQueryItem(name: "apiVersion", value: "2"),
            URLQueryItem(name: "bbox", value: box.queryValue),
            URLQueryItem(name: "timeValidity", value: "present")
        ]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "TomTom-Api-Key")
        request.setValue("2", forHTTPHeaderField: "TomTom-Api-Version")
        request.setValue("incidents(type,geometry(type,coordinates),properties(id,events(description),delayInSeconds,iconCategory,magnitudeOfDelay))",
                         forHTTPHeaderField: "Attributes")
        request.setValue("pl-PL", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await load(request)
        guard !data.isEmpty else { return [] }
        let features = try JSONDecoder().decode(IncidentResponse.self, from: data).incidents
        return features.compactMap { feature in
            let points = feature.geometry.points
            guard !points.isEmpty else { return nil }
            let description = feature.properties.events?.first?.description ?? "Utrudnienie drogowe"
            return TrafficIncident(id: feature.properties.id ?? UUID().uuidString,
                                   description: description, coordinate: points[points.count / 2],
                                   delaySeconds: feature.properties.delayInSeconds,
                                   category: TrafficIncidentCategory(tomTomValue: feature.properties.iconCategory),
                                   severity: TrafficIncidentSeverity(tomTomValue: feature.properties.magnitudeOfDelay),
                                   geometry: points)
        }
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        return try await load(request)
    }

    private func load(_ request: URLRequest) async throws -> Data {
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
        let delayInSeconds: Int?
        let iconCategory: String?
        let magnitudeOfDelay: String?
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
