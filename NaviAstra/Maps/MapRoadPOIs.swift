import Foundation

nonisolated enum MapSafetyPOICategory: Int, CaseIterable, Identifiable, Sendable {
    case speedCameras
    case surveillanceCameras
    case trafficSignals

    var id: Int { rawValue }
    var mask: Int { 1 << rawValue }
    static var allMask: Int { allCases.reduce(0) { $0 | $1.mask } }

    var title: String {
        switch self {
        case .speedCameras: "Fotoradary i pomiar odcinkowy"
        case .surveillanceCameras: "Kamery monitoringu"
        case .trafficSignals: "Sygnalizacja świetlna"
        }
    }

    var symbolName: String {
        switch self {
        case .speedCameras: "speedometer"
        case .surveillanceCameras: "video.fill"
        case .trafficSignals: "trafficlight.fill"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .speedCameras, .trafficSignals: NaviAstraColorPalette.warning
        case .surveillanceCameras: NaviAstraColorPalette.transitFallback
        }
    }

    var priority: Int { rawValue }
}

nonisolated enum MapRoadPOIStatus: Equatable, Sendable {
    case disabled
    case zoomIn
    case loading
    case loaded(count: Int)
    case unavailable
}

nonisolated struct MapRoadPOI: Identifiable, Equatable, Sendable {
    let id: String
    let category: MapSafetyPOICategory
    let coordinate: Coordinate
    let title: String
    let subtitle: String

    init(id: String, category: MapSafetyPOICategory, coordinate: Coordinate,
         title: String, subtitle: String = "© OpenStreetMap contributors") {
        self.id = id
        self.category = category
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }

}

extension RoadAlertType {
    nonisolated var mapSafetyPOICategory: MapSafetyPOICategory? {
        switch self {
        case .speedCamera, .averageSpeedStart, .averageSpeedEnd:
            .speedCameras
        case .redLightCamera:
            .surveillanceCameras
        default:
            nil
        }
    }
}

nonisolated struct MapRoadPOIQuery: Hashable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    let categories: Set<MapSafetyPOICategory>

    var id: String {
        let bounds = [south, west, north, east]
            .map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",")
        let categoryIDs = categories.sorted { $0.rawValue < $1.rawValue }
            .map { String($0.rawValue) }.joined(separator: ",")
        return "\(bounds)|\(categoryIDs)|\(MapRoadPOIEndpoint.url.absoluteString)"
    }

    var overpassQL: String {
        let bounds = [south, west, north, east]
            .map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",")
        var selectors: [String] = []
        if categories.contains(.speedCameras) {
            selectors.append("node[\"highway\"=\"speed_camera\"](\(bounds));")
        }
        if categories.contains(.surveillanceCameras) {
            selectors.append("nwr[\"man_made\"=\"surveillance\"](\(bounds));")
            selectors.append("nwr[\"camera:type\"=\"traffic\"](\(bounds));")
            selectors.append("nwr[\"contact:webcam\"](\(bounds));")
            selectors.append("node[\"highway\"=\"speed_camera\"][\"camera:type\"=\"red_light\"](\(bounds));")
            selectors.append("node[\"highway\"=\"speed_camera\"][\"enforcement\"=\"traffic_signals\"](\(bounds));")
        }
        if categories.contains(.trafficSignals) {
            selectors.append("node[\"highway\"=\"traffic_signals\"](\(bounds));")
        }
        var relationSelectors: [String] = []
        if categories.contains(.speedCameras) {
            relationSelectors.append("relation[\"type\"=\"enforcement\"][\"enforcement\"=\"average_speed\"](\(bounds));")
        }
        if categories.contains(.surveillanceCameras) {
            relationSelectors.append("relation[\"type\"=\"enforcement\"][\"enforcement\"=\"traffic_signals\"](\(bounds));")
        }
        let enforcementRelations = relationSelectors.isEmpty ? "" : """
        (
          \(relationSelectors.joined(separator: "\n  "))
        );
        out geom;
        """
        return """
        [out:json][timeout:20];
        (
          \(selectors.joined(separator: "\n  "))
        );
        out center tags;
        \(enforcementRelations)
        """
    }

    static func visible(center: Coordinate, latitudeDelta: Double, longitudeDelta: Double,
                        categories: Set<MapSafetyPOICategory>) -> MapRoadPOIQuery? {
        guard center.latitude.isFinite, center.longitude.isFinite,
              latitudeDelta.isFinite, longitudeDelta.isFinite,
              latitudeDelta > 0, longitudeDelta > 0,
              latitudeDelta <= 1.25, longitudeDelta <= 0.80 else { return nil }

        var visibleCategories = categories
        if latitudeDelta > 0.40 || longitudeDelta > 0.50 {
            visibleCategories.remove(.surveillanceCameras)
        }
        // Signalized intersections are dense in cities; fetch them only at a close map zoom.
        if latitudeDelta > 0.10 || longitudeDelta > 0.15 {
            visibleCategories.remove(.trafficSignals)
        }
        guard !visibleCategories.isEmpty else { return nil }

        let step = 0.025
        let south = max(-90, floor((center.latitude - latitudeDelta / 2) / step) * step)
        let north = min(90, ceil((center.latitude + latitudeDelta / 2) / step) * step)
        let west = max(-180, floor((center.longitude - longitudeDelta / 2) / step) * step)
        let east = min(180, ceil((center.longitude + longitudeDelta / 2) / step) * step)
        guard north > south, east > west else { return nil }
        return MapRoadPOIQuery(south: south, west: west, north: north, east: east,
                               categories: visibleCategories)
    }
}

actor MapRoadPOIProvider {
    static let shared = MapRoadPOIProvider()

    private struct CacheEntry {
        let points: [MapRoadPOI]
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<[MapRoadPOI], Error>] = [:]
    private var preferredEndpoint: URL?

    func points(in query: MapRoadPOIQuery) async throws -> [MapRoadPOI] {
        if let entry = cache[query.id], Date().timeIntervalSince(entry.fetchedAt) < 30 * 60 {
            return entry.points
        }
        if let task = inFlight[query.id] { return try await task.value }

        let task = Task { try await self.download(query) }
        inFlight[query.id] = task
        do {
            let points = try await task.value
            cache[query.id] = CacheEntry(points: points, fetchedAt: .now)
            inFlight[query.id] = nil
            trimCacheIfNeeded()
            return points
        } catch {
            inFlight[query.id] = nil
            throw error
        }
    }

    private func trimCacheIfNeeded() {
        guard cache.count > 64 else { return }
        let oldestKeys = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(cache.count - 64).map(\.key)
        oldestKeys.forEach { cache[$0] = nil }
    }

    private func download(_ query: MapRoadPOIQuery) async throws -> [MapRoadPOI] {
        let endpoints = MapRoadPOIEndpoint.urls
        let orderedEndpoints: [URL]
        if let preferredEndpoint, endpoints.contains(preferredEndpoint) {
            orderedEndpoints = [preferredEndpoint] + endpoints.filter { $0 != preferredEndpoint }
        } else {
            orderedEndpoints = endpoints
        }

        var lastError: Error = MapRoadPOIError.unavailable
        for endpoint in orderedEndpoints {
            do {
                try Task.checkCancellation()
                let points = try await Self.download(query, from: endpoint)
                preferredEndpoint = endpoint
                return points
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func download(_ query: MapRoadPOIQuery, from endpoint: URL) async throws -> [MapRoadPOI] {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NaviAstra/1.0 (OpenStreetMap safety points)", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query.overpassQL)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        guard await OSMCyclingRequestGate.shared.waitUntilAllowed() else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw MapRoadPOIError.unavailable
            }
            let decoded = try JSONDecoder().decode(MapRoadPOIResponse.self, from: data)
            guard decoded.remark == nil else { throw MapRoadPOIError.unavailable }
            try Task.checkCancellation()
            await OSMCyclingRequestGate.shared.requestDidFinish()
            return parseElements(decoded.elements, categories: query.categories)
        } catch {
            await OSMCyclingRequestGate.shared.requestDidFinish()
            throw error
        }
    }

    private static func parseElements(_ elements: [MapRoadPOIElement],
                                      categories: Set<MapSafetyPOICategory>) -> [MapRoadPOI] {
        var unique: [String: MapRoadPOI] = [:]
        for element in elements {
            if element.type == "relation", let enforcement = element.tags?["enforcement"] {
                if enforcement == "average_speed", categories.contains(.speedCameras) {
                    let sections = element.members?.filter { $0.role == "section" } ?? []
                    let start = element.members?.first(where: { $0.role == "from" })?.coordinate
                        ?? sections.first?.geometry?.first?.coordinate
                    let end = element.members?.first(where: { $0.role == "to" })?.coordinate
                        ?? sections.last?.geometry?.last?.coordinate
                    for (suffix, coordinate, title) in [
                        ("start", start, "Początek odcinkowego pomiaru"),
                        ("end", end, "Koniec odcinkowego pomiaru")
                    ] {
                        guard let coordinate else { continue }
                        let speed = SpeedLimitParser.parse(element.tags?["maxspeed"])
                        let detail = speed.map { "Limit \($0) km/h · " } ?? ""
                        let point = MapRoadPOI(
                            id: "osm-relation-\(element.id)-\(suffix)",
                            category: .speedCameras,
                            coordinate: coordinate,
                            title: title,
                            subtitle: "\(detail)© OpenStreetMap contributors")
                        unique[point.id] = point
                    }
                } else if enforcement == "traffic_signals", categories.contains(.surveillanceCameras) {
                    let devices = element.members?.filter { $0.role == "device" }
                        .compactMap(\.coordinate) ?? []
                    for (index, coordinate) in devices.enumerated() {
                        let point = MapRoadPOI(
                            id: "osm-relation-\(element.id)-redlight-\(index)",
                            category: .surveillanceCameras,
                            coordinate: coordinate,
                            title: "Kamera rejestrująca przejazd na czerwonym")
                        unique[point.id] = point
                    }
                }
                continue
            }
            guard let tags = element.tags,
                  let latitude = element.lat ?? element.center?.lat,
                  let longitude = element.lon ?? element.center?.lon,
                  latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  let category = category(for: tags), categories.contains(category) else { continue }

            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            let osmID = "osm-\(element.type)-\(element.id)"
            let knownID = element.type == "node" ? "osm-node-\(element.id)" : osmID
            let name = tags["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle(for: category, tags: tags)
            let detail: String?
            if category == .speedCameras, let speed = SpeedLimitParser.parse(tags["maxspeed"]) {
                detail = "Limit \(speed) km/h"
            } else {
                detail = tags["operator"]
            }
            let subtitle = [detail, "© OpenStreetMap contributors"].compactMap { $0 }
                .joined(separator: " · ")
            let point = MapRoadPOI(id: knownID, category: category, coordinate: coordinate,
                                   title: title, subtitle: subtitle)
            if let existing = unique[knownID], existing.category.priority <= category.priority { continue }
            unique[knownID] = point
        }
        return unique.values.sorted {
            if $0.category.priority != $1.category.priority {
                return $0.category.priority < $1.category.priority
            }
            return $0.id < $1.id
        }.prefix(1_200).map { $0 }
    }

    private static func category(for tags: [String: String]) -> MapSafetyPOICategory? {
        if tags["highway"] == "speed_camera" {
            return tags["enforcement"] == "traffic_signals" || tags["camera:type"] == "red_light"
                ? .surveillanceCameras : .speedCameras
        }
        if tags["highway"] == "traffic_signals" { return .trafficSignals }
        if tags["man_made"] == "surveillance" {
            let surveillanceType = tags["surveillance:type"]?.lowercased()
            guard surveillanceType == nil || surveillanceType == "camera" || surveillanceType == "alpr" else {
                return nil
            }
            return .surveillanceCameras
        }
        if tags["camera:type"] == "traffic" || tags["contact:webcam"] != nil { return .surveillanceCameras }
        return nil
    }

    private static func defaultTitle(for category: MapSafetyPOICategory, tags: [String: String]) -> String {
        switch category {
        case .speedCameras: "Fotoradar"
        case .surveillanceCameras:
            if tags["camera:type"] == "red_light" || tags["enforcement"] == "traffic_signals" {
                "Kamera rejestrująca przejazd na czerwonym"
            } else if tags["surveillance:type"] == "ALPR" {
                "Kamera kontroli ruchu"
            } else {
                "Kamera monitoringu"
            }
        case .trafficSignals: "Sygnalizacja świetlna"
        }
    }
}

nonisolated private enum MapRoadPOIEndpoint {
    static var url: URL {
        let configured = UserDefaults.standard.string(forKey: "overpassServer")
        return configured.flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
            ?? URL(string: "https://overpass-api.de/api/interpreter")!
    }

    static var urls: [URL] {
        let endpoints = [
            url,
            URL(string: "https://overpass.private.coffee/api/interpreter")!
        ]
        var unique: [URL] = []
        for endpoint in endpoints where !unique.contains(endpoint) {
            unique.append(endpoint)
        }
        return unique
    }
}

nonisolated private struct MapRoadPOIResponse: Decodable {
    let elements: [MapRoadPOIElement]
    let remark: String?
}

nonisolated private struct MapRoadPOIElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: Center?
    let tags: [String: String]?
    let members: [Member]?

    nonisolated struct Center: Decodable {
        let lat: Double
        let lon: Double
    }

    nonisolated struct Member: Decodable {
        let role: String
        let lat: Double?
        let lon: Double?
        let geometry: [Location]?

        var coordinate: Coordinate? {
            if let lat, let lon { return Coordinate(latitude: lat, longitude: lon) }
            return geometry?.first?.coordinate
        }
    }

    nonisolated struct Location: Decodable {
        let lat: Double
        let lon: Double

        var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }
}

nonisolated private enum MapRoadPOIError: Error {
    case unavailable
}
