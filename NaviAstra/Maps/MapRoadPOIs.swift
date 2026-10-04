import Foundation

nonisolated enum MapSafetyPOICategory: Int, CaseIterable, Identifiable, Codable, Sendable {
    case speedCameras
    case surveillanceCameras
    case trafficSignals
    case heightLimits
    case weightLimits
    case truckRestrictions
    case trafficSigns

    var id: Int { rawValue }
    var mask: Int { 1 << rawValue }
    static var allMask: Int { allCases.reduce(0) { $0 | $1.mask } }

    var title: String {
        switch self {
        case .speedCameras: "Fotoradary, pomiar odcinkowy i czerwone światło"
        case .surveillanceCameras: "Kamery monitoringu"
        case .trafficSignals: "Sygnalizacja świetlna"
        case .heightLimits: "Ograniczenia wysokości (B-16)"
        case .weightLimits: "Ograniczenia masy (B-18)"
        case .truckRestrictions: "Zakaz wjazdu ciężarówek (B-5)"
        case .trafficSigns: "Znaki drogowe"
        }
    }

    var symbolName: String {
        switch self {
        case .speedCameras: "speedometer"
        case .surveillanceCameras: "video.fill"
        case .trafficSignals: "trafficlight.fill"
        case .heightLimits: "arrow.up.and.down"
        case .weightLimits: "scalemass.fill"
        case .truckRestrictions: "truck.box.fill"
        case .trafficSigns: "signpost.right.fill"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .speedCameras, .trafficSignals, .heightLimits, .weightLimits, .truckRestrictions, .trafficSigns: NaviAstraColorPalette.warning
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

nonisolated struct MapRoadPOI: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let category: MapSafetyPOICategory
    let coordinate: Coordinate
    let title: String
    let subtitle: String
    var signCode: String? = nil
    var signSpeedLimit: Int? = nil
    var heightValue: String? = nil
    var weightValue: String? = nil
    var signSource: RoadSignSource? = nil

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
        case .heightLimitSign:
            .heightLimits
        case .weightLimitSign:
            .weightLimits
        default:
            nil
        }
    }
}

extension RoadSafetyAlert {
    nonisolated var mapSafetyPOICategory: MapSafetyPOICategory? {
        if type == .trafficSign, OSMWeightRestriction.isTruckSign(signCode) { return .truckRestrictions }
        return type.mapSafetyPOICategory
    }
}

nonisolated struct MapRoadPOIQuery: Hashable, Codable, Sendable {
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

    var id: String { cacheID(endpoint: MapRoadPOIEndpoint.url.absoluteString) }

    func cacheID(endpoint: String) -> String {
        let bounds = [south, west, north, east]
            .map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",")
        let categoryIDs = categories.sorted { $0.rawValue < $1.rawValue }
            .map { String($0.rawValue) }.joined(separator: ",")
        return "\(bounds)|\(categoryIDs)|\(endpoint)"
    }

    var overpassQL: String {
        let bounds = [south, west, north, east]
            .map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",")
        var selectors: [String] = []
        if categories.contains(.trafficSigns) {
            for key in ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"] {
                selectors.append("nwr[\"\(key)\"](\(bounds));")
            }
            selectors.append("node[\"highway\"~\"^(stop|give_way)$\"](\(bounds));")
        }
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
        var restrictionSelectors: [String] = []
        if categories.contains(.heightLimits) {
            restrictionSelectors.append("node[\"maxheight\"](\(bounds));")
            restrictionSelectors.append("way[\"highway\"][\"maxheight\"](\(bounds));")
            for key in ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"] {
                restrictionSelectors.append("node[\"\(key)\"~\"(^|;)(maxheight|PL:B-16|B-16)(;|$)\"](\(bounds));")
            }
            restrictionSelectors.append("node[\"traffic_sign:maxheight\"](\(bounds));")
        }
        if categories.contains(.weightLimits) {
            restrictionSelectors.append("node[\"maxweight\"](\(bounds));")
            restrictionSelectors.append("way[\"highway\"][\"maxweight\"](\(bounds));")
            restrictionSelectors.append("node[\"traffic_sign:maxweight\"](\(bounds));")
        }
        if categories.contains(.truckRestrictions) {
            restrictionSelectors.append("node[\"maxweightrating:hgv\"](\(bounds));")
            restrictionSelectors.append("way[\"highway\"][\"maxweightrating:hgv\"](\(bounds));")
            restrictionSelectors.append("node[\"hgv\"=\"no\"](\(bounds));")
            restrictionSelectors.append("way[\"highway\"][\"hgv\"=\"no\"](\(bounds));")
        }
        for key in ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"] {
            if categories.contains(.weightLimits) {
                restrictionSelectors.append("node[\"\(key)\"~\"(^|;)(maxweight|PL:B-18|B-18)(;|$|[[])\"](\(bounds));")
            }
            if categories.contains(.truckRestrictions) {
                restrictionSelectors.append("node[\"\(key)\"~\"(^|;)(PL:B-5|B-5)(;|$|[[])\"](\(bounds));")
            }
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
        let roadRestrictions = restrictionSelectors.isEmpty ? "" : """
        (
          \(restrictionSelectors.joined(separator: "\n  "))
        );
        out geom;
        """
        return """
        [out:json][timeout:20];
        (
          \(selectors.joined(separator: "\n  "))
        );
        out center tags;
        \(roadRestrictions)
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
            visibleCategories.remove(.trafficSigns)
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

nonisolated struct MapRoadPOIResult: Codable, Sendable {
    let points: [MapRoadPOI]
    var unavailableSources: [String] = []
}

actor MapRoadPOIProvider {
    static let shared = MapRoadPOIProvider()

    private struct CacheEntry: Codable {
        let query: MapRoadPOIQuery
        let endpoint: String
        let result: MapRoadPOIResult
        let fetchedAt: Date

        var isFresh: Bool {
            let age = Date().timeIntervalSince(fetchedAt)
            // Incomplete results keep their source warning and only suppress short retry bursts.
            let lifetime: TimeInterval = result.unavailableSources.isEmpty ? 86_400 : 60
            return age >= 0 && age < lifetime
        }
    }

    private var cache: [String: CacheEntry] = [:]
    private var restoredCache = false
    private var inFlight: [String: Task<MapRoadPOIResult, Error>] = [:]
    private var inFlightQueries: [String: MapRoadPOIQuery] = [:]
    private var preferredEndpoint: URL?

    func cachedPoints(in query: MapRoadPOIQuery) -> MapRoadPOIResult? {
        restoreCacheIfNeeded()
        let endpoint = MapRoadPOIEndpoint.url.absoluteString
        if let entry = cache[query.id], entry.isFresh,
           entry.endpoint == endpoint, entry.query.contains(query) {
            return filtered(entry.result, in: query)
        }
        // A closer view or fewer enabled categories reuse the already downloaded area.
        let coveringEntry = cache.values.filter {
            $0.isFresh && $0.endpoint == endpoint && $0.query.contains(query)
        }.min {
            ($0.query.north - $0.query.south) * ($0.query.east - $0.query.west)
                < ($1.query.north - $1.query.south) * ($1.query.east - $1.query.west)
        }
        return coveringEntry.map { filtered($0.result, in: query) }
    }

    func points(in query: MapRoadPOIQuery) async throws -> MapRoadPOIResult {
        if let cached = cachedPoints(in: query) { return cached }
        let queryID = query.id
        let endpoint = MapRoadPOIEndpoint.url.absoluteString
        // Reuse a pending wider request after zooming in instead of downloading twice.
        if let covering = inFlightQueries.first(where: {
            $0.value.contains(query) && $0.key.hasSuffix("|" + endpoint)
        }), let task = inFlight[covering.key] {
            return filtered(try await task.value, in: query)
        }

        let task = Task { try await self.loadCombined(query) }
        inFlight[queryID] = task
        inFlightQueries[queryID] = query
        defer {
            inFlight[queryID] = nil
            inFlightQueries[queryID] = nil
        }
        let points = try await task.value
        cache[queryID] = CacheEntry(query: query, endpoint: endpoint,
                                   result: points, fetchedAt: .now)
        trimCacheIfNeeded()
        if points.unavailableSources.isEmpty { persistCache() }
        return filtered(points, in: query)
    }

    private func filtered(_ result: MapRoadPOIResult, in query: MapRoadPOIQuery) -> MapRoadPOIResult {
        MapRoadPOIResult(points: result.points.filter { query.contains($0) },
                         unavailableSources: result.unavailableSources)
    }

    private func trimCacheIfNeeded() {
        cache = cache.filter { $0.value.isFresh }
        guard cache.count > 64 else { return }
        let oldestKeys = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(cache.count - 64).map(\.key)
        oldestKeys.forEach { cache[$0] = nil }
    }

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NaviAstra/MapRoadPOIs/v1.json")
    }

    private func restoreCacheIfNeeded() {
        guard !restoredCache else { return }
        restoredCache = true
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data) else { return }
        for entry in entries where entry.isFresh && entry.result.unavailableSources.isEmpty {
            cache[entry.query.cacheID(endpoint: entry.endpoint)] = entry
        }
        trimCacheIfNeeded()
    }

    private func persistCache() {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(cache.values.filter {
                  $0.isFresh && $0.result.unavailableSources.isEmpty
              }) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
            if categories.contains(.trafficSigns), let tags = element.tags,
               let latitude = element.lat ?? element.center?.lat,
               let longitude = element.lon ?? element.center?.lon,
               latitude.isFinite, longitude.isFinite,
               (-90...90).contains(latitude), (-180...180).contains(longitude) {
                let codes = OSMTrafficSignCodes.parse(tags)
                for (index, code) in codes.enumerated() {
                    let id = "osm-sign-\(element.type)-\(element.id)-\(index)"
                    let locationNote = element.type == "node" ? nil : "Lokalizacja przybliżona — znak przypisany do obiektu OSM"
                    var point = MapRoadPOI(id: id, category: .trafficSigns,
                        coordinate: Coordinate(latitude: latitude, longitude: longitude),
                        title: "Znak drogowy · \(code)",
                        subtitle: [tags["name"], locationNote, "© OpenStreetMap contributors"]
                            .compactMap { $0 }.joined(separator: " · "))
                    point.signCode = code
                    point.signSource = .explicitTrafficSign
                    point.signSpeedLimit = SpeedLimitParser.parse(tags["maxspeed"])
                    point.heightValue = OSMHeightRestriction.parse(tags)?.value
                    let baseCode = code.uppercased().split(separator: ":").last?
                        .split(separator: "[").first.map(String.init)
                    point.weightValue = OSMWeightRestriction.parse(tags).first {
                        $0.kind == (baseCode == "B-5" ? .trucks : .actualMass)
                    }?.value
                    unique[id] = point
                }
                // An explicit sign is already represented by this independent layer.
                if !codes.isEmpty { continue }
            }
            if categories.contains(.heightLimits), let tags = element.tags,
               let restriction = OSMHeightRestriction.parse(tags),
               let coordinate = element.type == "way" ? element.geometry?.first?.coordinate
                    : element.lat.flatMap({ lat in element.lon.map { Coordinate(latitude: lat, longitude: $0) } }),
               coordinate.latitude.isFinite, coordinate.longitude.isFinite,
               (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) {
                let id = "osm-height-\(element.type)-\(element.id)"
                var point = MapRoadPOI(id: id, category: .heightLimits, coordinate: coordinate,
                                       title: "Ograniczenie wysokości",
                                       subtitle: restriction.subtitle)
                point.heightValue = restriction.value
                point.signSource = restriction.source
                unique[id] = point
            }
            if let tags = element.tags,
               let coordinate = element.type == "way" ? element.geometry?.first?.coordinate
                    : element.lat.flatMap({ lat in element.lon.map { Coordinate(latitude: lat, longitude: $0) } }),
               coordinate.latitude.isFinite, coordinate.longitude.isFinite,
               (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) {
                for restriction in OSMWeightRestriction.parse(tags) where categories.contains(restriction.category) {
                    let id = "osm-\(restriction.idPrefix)-\(element.type)-\(element.id)"
                    var point = MapRoadPOI(id: id, category: restriction.category, coordinate: coordinate,
                                           title: restriction.title, subtitle: restriction.subtitle)
                    point.weightValue = restriction.value
                    point.signSource = restriction.source
                    unique[id] = point
                }
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
        let points = unique.values.filter { point in
            guard [.heightLimits, .weightLimits, .truckRestrictions].contains(point.category),
                  point.signSource == .inferredFromRoadRestriction else { return true }
            return !unique.values.contains { explicit in
                explicit.category == point.category && explicit.signSource == .explicitTrafficSign
                    && explicit.heightValue == point.heightValue && explicit.weightValue == point.weightValue
                    && explicit.coordinate.distance(to: point.coordinate) < 20
            }
        }
        return points.sorted {
            if $0.category.priority != $1.category.priority {
                return $0.category.priority < $1.category.priority
            }
            return $0.id < $1.id
        }
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
        case .heightLimits: "Ograniczenie wysokości"
        case .weightLimits: "Ograniczenie masy"
        case .truckRestrictions: "Zakaz wjazdu samochodów ciężarowych"
        case .trafficSigns: "Znak drogowy"
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
    let geometry: [Location]?
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

nonisolated enum RoadSignSource: String, Codable, Sendable {
    case explicitTrafficSign
    case inferredFromRoadRestriction

    var title: String {
        switch self {
        case .explicitTrafficSign: "Znak oznaczony w OSM"
        case .inferredFromRoadRestriction: "Punkt wyznaczony z ograniczenia na drodze"
        }
    }
}

// Shared by viewport POIs and route signs; physical clearance is deliberately excluded.
nonisolated struct OSMHeightRestriction {
    let value: String?
    let source: RoadSignSource

    var subtitle: String {
        [value.map { "Maksymalna wysokość: \($0)" } ?? "Wysokość niepodana",
         source.title, "Źródło: OpenStreetMap · © OpenStreetMap contributors"].joined(separator: " · ")
    }

    static func parse(_ tags: [String: String]) -> Self? {
        let codes = ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"]
            .compactMap { tags[$0] }.flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        let explicit = codes.contains { ["MAXHEIGHT", "B-16", "PL:B-16"].contains($0) }
            || tags["traffic_sign:maxheight"] != nil
        let value = formattedMeters(tags["traffic_sign:maxheight"]) ?? formattedMeters(tags["maxheight"])
        guard explicit || value != nil else { return nil }
        return Self(value: value, source: explicit ? .explicitTrafficSign : .inferredFromRoadRestriction)
    }

    static func formattedMeters(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".")
        let meters: Double
        if let apostrophe = input.firstIndex(of: "'") {
            let feetText = input[..<apostrophe]
            let inchesText = input[input.index(after: apostrophe)...]
            guard inchesText.hasSuffix("\""), let feet = Double(feetText),
                  let inches = Double(inchesText.dropLast()), feet >= 0, (0..<12).contains(inches) else { return nil }
            meters = feet * 0.3048 + inches * 0.0254
        } else {
            let digits = input.prefix { $0.isNumber || $0 == "." }
            let unit = input.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            guard ["", "m", "meter", "meters", "metre", "metres"].contains(unit),
                  let parsed = Double(digits) else { return nil }
            meters = parsed
        }
        guard meters.isFinite, meters > 0 else { return nil }
        let formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), meters)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return formatted.replacingOccurrences(of: ".", with: ",") + " m"
    }
}

// B-18 concerns actual mass; B-5 concerns truck access / permitted gross mass.
nonisolated struct OSMWeightRestriction {
    enum Kind { case actualMass, trucks }
    let kind: Kind
    let value: String?
    let source: RoadSignSource

    var category: MapSafetyPOICategory { kind == .actualMass ? .weightLimits : .truckRestrictions }
    var code: String { kind == .actualMass ? "B-18" : "B-5" }
    var idPrefix: String { kind == .actualMass ? "weight" : "trucks" }
    var title: String { kind == .actualMass ? "Ograniczenie masy" : "Zakaz wjazdu samochodów ciężarowych" }
    var subtitle: String {
        let detail: String
        switch kind {
        case .actualMass: detail = value.map { "Maksymalna masa rzeczywista: \($0)" } ?? "Limit masy niepodany"
        case .trucks: detail = value.map { "Zakaz dla ciężarówek o DMC powyżej \($0)" }
            ?? "Zakaz wjazdu ciężarówek · Próg DMC niepodany w OSM"
        }
        return "\(code) · \(detail) · \(source.title) · Źródło: OpenStreetMap · © OpenStreetMap contributors"
    }

    nonisolated static func isTruckSign(_ raw: String?) -> Bool {
        signCodes(raw).contains { baseCode($0) == "B-5" }
    }

    nonisolated private static func signCodes(_ raw: String?) -> [String] {
        (raw ?? "").components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    }

    nonisolated private static func baseCode(_ code: String) -> String {
        let base = code.split(separator: "[").first ?? ""
        return String(base.split(separator: ":").last ?? base)
    }

    static func parse(_ tags: [String: String]) -> [Self] {
        let codes = ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"]
            .flatMap { signCodes(tags[$0]) }
        func embeddedValue(_ code: String) -> String? {
            guard let raw = codes.first(where: { baseCode($0) == code }),
                  let start = raw.firstIndex(of: "["), raw.hasSuffix("]") else { return nil }
            return formattedTonnes(String(raw[raw.index(after: start)..<raw.index(before: raw.endIndex)]))
        }
        var result: [Self] = []
        let explicitWeight = codes.contains { ["B-18", "MAXWEIGHT"].contains(baseCode($0)) }
            || tags["traffic_sign:maxweight"] != nil
        let weight = formattedTonnes(tags["traffic_sign:maxweight"])
            ?? embeddedValue("B-18") ?? formattedTonnes(tags["maxweight"])
        if explicitWeight || weight != nil {
            result.append(Self(kind: .actualMass, value: weight,
                               source: explicitWeight ? .explicitTrafficSign : .inferredFromRoadRestriction))
        }
        let explicitTruck = codes.contains { baseCode($0) == "B-5" }
        let truckWeight = embeddedValue("B-5") ?? formattedTonnes(tags["maxweightrating:hgv"])
            ?? (explicitTruck ? formattedTonnes(tags["maxweightrating"]) : nil)
        if explicitTruck || truckWeight != nil || tags["hgv"]?.lowercased() == "no" {
            result.append(Self(kind: .trucks, value: truckWeight,
                               source: explicitTruck ? .explicitTrafficSign : .inferredFromRoadRestriction))
        }
        return result
    }

    private static func formattedTonnes(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".")
        let digits = input.prefix { $0.isNumber || $0 == "." }
        let unit = input.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let number = Double(digits), number.isFinite, number > 0 else { return nil }
        let tonnes: Double
        switch unit {
        case "", "t", "tonne", "tonnes", "ton", "tons": tonnes = number
        case "kg": tonnes = number / 1_000
        default: return nil
        }
        let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), tonnes)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return formatted.replacingOccurrences(of: ".", with: ",") + " t"
    }
}

// Preserve every code on a signpost, including codes without a dedicated drawing.
nonisolated enum OSMTrafficSignCodes {
    static func parse(_ tags: [String: String]) -> [String] {
        var result: [String] = []
        for key in ["traffic_sign", "traffic_sign:forward", "traffic_sign:backward"] {
            var country: String?
            for part in (tags[key] ?? "").components(separatedBy: CharacterSet(charactersIn: ";,")) {
                var code = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty, !["no", "none"].contains(code.lowercased()) else { continue }
                if let colon = code.firstIndex(of: ":") {
                    country = String(code[..<colon])
                } else if let country {
                    code = "\(country):\(code)"
                }
                if !result.contains(code) { result.append(code) }
            }
        }
        if result.isEmpty {
            if tags["highway"] == "stop" { result = ["stop"] }
            if tags["highway"] == "give_way" { result = ["give_way"] }
        }
        return result
    }
}
