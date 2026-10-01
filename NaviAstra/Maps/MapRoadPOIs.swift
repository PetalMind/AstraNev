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
        case .speedCameras: "Fotoradary, pomiar odcinkowy i czerwone światło"
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
    case partial(count: Int, message: String)
    case unavailable

    var needsRetry: Bool {
        switch self {
        case .partial, .unavailable: true
        default: false
        }
    }
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
        case .speedCamera, .averageSpeedStart, .averageSpeedEnd, .redLightCamera:
            .speedCameras
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

    func contains(_ other: MapRoadPOIQuery) -> Bool {
        south <= other.south && west <= other.west && north >= other.north && east >= other.east
            && categories.isSuperset(of: other.categories)
    }

    func contains(_ point: MapRoadPOI) -> Bool {
        categories.contains(point.category)
            && (south...north).contains(point.coordinate.latitude)
            && (west...east).contains(point.coordinate.longitude)
    }

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
            selectors.append("node[\"enforcement\"=\"traffic_signals\"](\(bounds));")
            selectors.append("node[\"camera:type\"=\"red_light\"](\(bounds));")
        }
        if categories.contains(.surveillanceCameras) {
            selectors.append("nwr[\"man_made\"=\"surveillance\"](\(bounds));")
            selectors.append("nwr[\"camera:type\"=\"traffic\"](\(bounds));")
            selectors.append("nwr[\"contact:webcam\"](\(bounds));")
        }
        if categories.contains(.trafficSignals) {
            selectors.append("node[\"highway\"=\"traffic_signals\"](\(bounds));")
            selectors.append("node[\"highway\"=\"crossing\"][\"crossing\"=\"traffic_signals\"](\(bounds));")
            selectors.append("node[\"highway\"=\"crossing\"][\"crossing:signals\"=\"yes\"](\(bounds));")
        }
        var relationSelectors: [String] = []
        if categories.contains(.speedCameras) {
            relationSelectors.append("relation[\"type\"=\"enforcement\"][\"enforcement\"~\"^(maxspeed|average_speed|traffic_signals)$\"](\(bounds));")
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

nonisolated struct MapRoadPOIResult: Sendable {
    let points: [MapRoadPOI]
    var unavailableSources: [String] = []
}

actor MapRoadPOIProvider {
    static let shared = MapRoadPOIProvider()

    private struct CacheEntry {
        let query: MapRoadPOIQuery
        let endpoint: String
        let result: MapRoadPOIResult
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<MapRoadPOIResult, Error>] = [:]
    private var preferredEndpoint: URL?

    func points(in query: MapRoadPOIQuery) async throws -> MapRoadPOIResult {
        let queryID = query.id
        let endpoint = MapRoadPOIEndpoint.url.absoluteString
        if let entry = cache[queryID], Date().timeIntervalSince(entry.fetchedAt) < 30 * 60 {
            return entry.result
        }
        // A closer view can reuse complete data already downloaded for a larger area.
        let coveringEntry = cache.values.filter {
            Date().timeIntervalSince($0.fetchedAt) < 30 * 60
                && $0.endpoint == endpoint
                && $0.query.contains(query)
        }.min {
            ($0.query.north - $0.query.south) * ($0.query.east - $0.query.west)
                < ($1.query.north - $1.query.south) * ($1.query.east - $1.query.west)
        }
        if let entry = coveringEntry {
            return MapRoadPOIResult(points: entry.result.points.filter { query.contains($0) })
        }
        if let task = inFlight[queryID] { return try await task.value }

        let task = Task { try await self.loadCombined(query) }
        inFlight[queryID] = task
        do {
            let points = try await task.value
            if points.unavailableSources.isEmpty {
                cache[queryID] = CacheEntry(query: query, endpoint: endpoint,
                                          result: points, fetchedAt: .now)
            }
            inFlight[queryID] = nil
            trimCacheIfNeeded()
            return points
        } catch {
            inFlight[queryID] = nil
            throw error
        }
    }

    private func trimCacheIfNeeded() {
        guard cache.count > 64 else { return }
        let oldestKeys = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(cache.count - 64).map(\.key)
        oldestKeys.forEach { cache[$0] = nil }
    }

    private func loadCombined(_ query: MapRoadPOIQuery) async throws -> MapRoadPOIResult {
        guard query.categories.contains(.speedCameras), CANARDRoadDataProvider.intersects(query) else {
            return MapRoadPOIResult(points: try await download(query))
        }
        async let osm = RoadSafetyFetch.capture { try await self.download(query) }
        async let canard = RoadSafetyFetch.capture { try await CANARDRoadDataProvider.shared.load() }
        let (osmResult, canardResult) = await (osm, canard)
        let official: [MapRoadPOI]
        if case .success(let snapshot) = canardResult {
            official = snapshot.alerts.filter {
                (query.south...query.north).contains($0.coordinate.latitude) &&
                    (query.west...query.east).contains($0.coordinate.longitude)
            }.map {
                MapRoadPOI(id: $0.id, category: .speedCameras, coordinate: $0.coordinate,
                           title: $0.title, subtitle: CANARDRoadDataProvider.attribution)
            }
        } else { official = [] }
        switch (osmResult, canardResult) {
        case (.success(let points), .success):
            let merged = points + official.filter { device in
                !points.contains { $0.category == .speedCameras && $0.coordinate.distance(to: device.coordinate) < 40 }
            }
            return MapRoadPOIResult(points: merged)
        case (.success(let points), .failure):
            return MapRoadPOIResult(points: points, unavailableSources: ["CANARD"])
        case (.failure, .success):
            return MapRoadPOIResult(points: official, unavailableSources: ["OpenStreetMap"])
        case (.failure(let error), .failure): throw error
        }
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
        // Process relations last so their richer classification overrides bare device tags.
        for element in elements.sorted(by: { ($0.type == "relation" ? 1 : 0) < ($1.type == "relation" ? 1 : 0) }) {
            if element.type == "relation", element.tags?["type"] == "enforcement",
               let enforcement = element.tags?["enforcement"] {
                if enforcement == "average_speed", categories.contains(.speedCameras) {
                    for member in element.members ?? [] where member.role == "device" {
                        if let id = member.osmID { unique[id] = nil }
                    }
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
                } else if ["traffic_signals", "maxspeed"].contains(enforcement),
                          categories.contains(.speedCameras) {
                    let devices = element.members?.filter { $0.role == "device" } ?? []
                    for (index, device) in devices.enumerated() {
                        guard let coordinate = device.coordinate else { continue }
                        let speed = SpeedLimitParser.parse(element.tags?["maxspeed"])
                        let detail = speed.map { "Limit \($0) km/h · " } ?? ""
                        let point = MapRoadPOI(
                            id: device.osmID ?? "osm-relation-\(element.id)-camera-\(index)",
                            category: .speedCameras,
                            coordinate: coordinate,
                            title: enforcement == "traffic_signals"
                                ? "Kamera rejestrująca przejazd na czerwonym" : "Fotoradar",
                            subtitle: "\(detail)© OpenStreetMap contributors")
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
                  let category = category(for: tags, categories: categories) else { continue }

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

    private static func category(for tags: [String: String],
                                 categories: Set<MapSafetyPOICategory>) -> MapSafetyPOICategory? {
        if OSMSafetyTags.enforcementType(tags) != nil, categories.contains(.speedCameras) { return .speedCameras }
        if OSMSafetyTags.isTrafficSignal(tags), categories.contains(.trafficSignals) { return .trafficSignals }
        guard categories.contains(.surveillanceCameras), OSMSafetyTags.enforcementType(tags) == nil else { return nil }
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
        case .speedCameras:
            OSMSafetyTags.enforcementType(tags) == .redLightCamera
                ? "Kamera rejestrująca przejazd na czerwonym" : "Fotoradar"
        case .surveillanceCameras:
            if tags["camera:type"] == "red_light" || tags["enforcement"] == "traffic_signals" {
                "Kamera rejestrująca przejazd na czerwonym"
            } else if tags["surveillance:type"]?.lowercased() == "alpr" {
                "Kamera kontroli ruchu"
            } else {
                "Kamera monitoringu"
            }
        case .trafficSignals: "Sygnalizacja świetlna"
        }
    }
}

nonisolated enum MapRoadPOIEndpoint {
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
        let type: String?
        let ref: Int64?
        var osmID: String? {
            guard let type, let ref else { return nil }
            return "osm-\(type)-\(ref)"
        }
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

// Both browsing and route warnings must interpret enforcement tags identically.
nonisolated enum OSMSafetyTags {
    static func enforcementType(_ tags: [String: String]) -> RoadAlertType? {
        if tags["enforcement"] == "traffic_signals" || tags["camera:type"] == "red_light" {
            return .redLightCamera
        }
        return tags["highway"] == "speed_camera" ? .speedCamera : nil
    }

    static func isTrafficSignal(_ tags: [String: String]) -> Bool {
        tags["highway"] == "traffic_signals" ||
            (tags["highway"] == "crossing" &&
                (tags["crossing"] == "traffic_signals" || tags["crossing:signals"] == "yes"))
    }
}
