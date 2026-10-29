#if os(iOS)
import Foundation
import OSLog

/// Raw OSM attributes are retained: a lane count never implies turn permissions or painted markings.
nonisolated struct DetailedRoad: Codable, Sendable {
    struct Point: Codable, Sendable {
        let latitude: Double
        let longitude: Double
    }
    let id: Int64
    let points: [Point]
    let tags: [String: String]
    /// Optional for compatibility with cached snapshots written before topology was retained.
    let nodeIDs: [Int64]?
}

nonisolated struct DetailedRoadQuery: Hashable, Codable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    var isValid: Bool {
        [south, west, north, east].allSatisfy(\.isFinite)
            && south >= -80 && north <= 80 && west >= -180 && east <= 180
            && north > south && east > west
    }

    var id: String {
        [south, west, north, east].map {
            String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), $0)
        }.joined(separator: ",")
    }

    /// A padded, quantized viewport supplies a margin for continuous navigation and avoids per-frame requests.
    static func visible(south: Double, west: Double, north: Double, east: Double,
                        zoom: Double) -> DetailedRoadQuery? {
        guard zoom.isFinite, zoom >= 16, [south, west, north, east].allSatisfy(\.isFinite),
              south >= -80, north <= 80, west >= -180, east <= 180,
              north > south, east > west else { return nil }
        let cosine = max(0.17, cos((south + north) / 2 * .pi / 180))
        let height = (north - south) * 111_320
        let width = (east - west) * 111_320 * cosine
        guard height <= 5_000, width <= 5_000 else { return nil }
        let latitudeStep = zoom >= 18 ? 0.002 : (zoom >= 17 ? 0.004 : 0.008)
        let longitudeStep = latitudeStep / max(0.17, cos(floor((south + north) / 2) * .pi / 180))
        let latitudeMargin = max((north - south) * 0.2, 60 / 111_320)
        let longitudeMargin = max((east - west) * 0.2, 60 / (111_320 * cosine))
        return DetailedRoadQuery(
            south: max(-80, floor((south - latitudeMargin) / latitudeStep) * latitudeStep),
            west: max(-180, floor((west - longitudeMargin) / longitudeStep) * longitudeStep),
            north: min(80, ceil((north + latitudeMargin) / latitudeStep) * latitudeStep),
            east: min(180, ceil((east + longitudeMargin) / longitudeStep) * longitudeStep))
    }

    func contains(south: Double, west: Double, north: Double, east: Double) -> Bool {
        south >= self.south && west >= self.west && north <= self.north && east <= self.east
    }

    func intersects(_ other: DetailedRoadQuery) -> Bool {
        north >= other.south && south <= other.north && east >= other.west && west <= other.east
    }

    var overpassQL: String {
        let bounds = id
        let roads = "^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"
        return """
        [out:json][timeout:20][maxsize:16777216];
        way["highway"~"\(roads)"](\(bounds));
        out geom;
        """
    }
}

actor OverpassDetailedRoadProvider: DetailedRoadDataProvider {
    static let shared = OverpassDetailedRoadProvider()
    nonisolated var sourceConfiguration: DetailedRoadSourceConfiguration { .shapes }
    private struct Entry: Codable, Sendable {
        let query: DetailedRoadQuery
        let endpoint: String
        let roads: [DetailedRoad]
        let fetchedAt: Date
        var isFresh: Bool { isUsable && Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 }
        var isUsable: Bool {
            let age = Date().timeIntervalSince(fetchedAt)
            // These are decorative map surfaces, never routing or access data.
            // Keep a bounded offline fallback while refreshing the 24-hour cache.
            return age >= -300 && age < 30 * 24 * 60 * 60 && query.isValid
        }
    }
    private var cache: [String: Entry] = [:]
    private var restored = false
    private let storageURL: URL?
    private let logger = Logger(subsystem: "NaviAstra", category: "DetailedRoads")

    init(cacheDirectory: URL? = nil) {
        storageURL = (cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)?
            .appendingPathComponent("NaviAstra/DetailedRoads/v2.json")
    }

    private var endpoint: URL {
        let configured = UserDefaults.standard.string(forKey: "overpassServer")
        return configured.flatMap(URL.init(string:))
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
            ?? URL(string: "https://overpass-api.de/api/interpreter")!
    }
    private func key(_ query: DetailedRoadQuery) -> String { endpoint.absoluteString + "|" + query.id }

    func cachedData(in query: DetailedRoadQuery) -> DetailedRoadData? {
        guard let cached = cachedRoads(in: query) else { return nil }
        return .roads(DetailedRoadSnapshot(roads: cached.roads, fetchedAt: cached.fetchedAt,
            revision: key(query) + "|" + cached.revision, coversQuery: cached.coversQuery))
    }

    func data(in query: DetailedRoadQuery) async throws -> DetailedRoadData {
        let roads = try await roads(in: query)
        let fetchedAt = cache[key(query)]?.fetchedAt ?? .now
        return .roads(DetailedRoadSnapshot(roads: roads, fetchedAt: fetchedAt,
            revision: key(query) + "|" + String(fetchedAt.timeIntervalSince1970)))
    }

    func cachedRoads(in query: DetailedRoadQuery) -> (roads: [DetailedRoad], coversQuery: Bool, fetchedAt: Date, revision: String)? {
        restore()
        let endpoint = endpoint.absoluteString
        let entries = cache.values.filter {
            $0.endpoint == endpoint && $0.isUsable && $0.query.contains(
                south: query.south, west: query.west, north: query.north, east: query.east)
        }.sorted { $0.fetchedAt > $1.fetchedAt }
        if let entry = entries.first {
            return (entry.roads, true, entry.fetchedAt,
                    entry.query.id + "|" + String(entry.fetchedAt.timeIntervalSince1970))
        }
        // A small pan must not discard every previously downloaded carriageway.
        // Partial coverage is publishable, but must never suppress a new request.
        let overlapping = cache.values.filter {
            $0.endpoint == endpoint && $0.isUsable && $0.query.intersects(query)
        }.sorted { $0.fetchedAt > $1.fetchedAt }
        guard let oldest = overlapping.last else { return nil }
        var roads: [Int64: DetailedRoad] = [:]
        var vertices = 0
        for entry in overlapping {
            for road in entry.roads where roads[road.id] == nil {
                guard roads.count < 4_000, vertices + road.points.count <= 80_000 else { continue }
                roads[road.id] = road
                vertices += road.points.count
            }
        }
        guard !roads.isEmpty else { return nil }
        let revision = overlapping.map { $0.query.id + "|" + String($0.fetchedAt.timeIntervalSince1970) }.joined(separator: ";")
        return (roads.values.sorted { $0.id < $1.id }, false, oldest.fetchedAt, revision)
    }

    func roads(in query: DetailedRoadQuery) async throws -> [DetailedRoad] {
        guard query.isValid else { throw URLError(.badURL) }
        restore()
        let cacheKey = key(query)
        if let entry = cache[cacheKey], entry.isFresh { return entry.roads }
        let endpoint = endpoint
        var request = URLRequest(url: endpoint, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NaviAstra", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query.overpassQL)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await OSMRequestTransport.shared.data(for: request, maximumDuration: 30)
        try Task.checkCancellation()
        guard data.count <= 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let roads = try Self.decode(data)
        cache[cacheKey] = Entry(query: query, endpoint: endpoint.absoluteString, roads: roads, fetchedAt: .now)
        trimAndPersist()
        logger.info("Detailed roads loaded: \(roads.count, privacy: .public)")
        return roads
    }

    private struct Response: Decodable {
        let elements: [Element]
        let remark: String?
        struct Element: Decodable {
            let type: String
            let id: Int64
            let tags: [String: String]?
            let geometry: [Point]?
            let nodes: [Int64]?
        }
        struct Point: Decodable {
            let lat: Double?
            let lon: Double?
        }
    }

    private static func decode(_ data: Data) throws -> [DetailedRoad] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.remark == nil, response.elements.count <= 4_000 else {
            throw URLError(.cannotParseResponse)
        }
        var result: [DetailedRoad] = []
        var vertexCount = 0
        for element in response.elements where element.type == "way" {
            guard let tags = element.tags, let geometry = element.geometry, geometry.count >= 2,
                  geometry.count <= 4_000 else { continue }
            // Reject incomplete geometry rather than connecting points across a missing section.
            let points = geometry.compactMap { point -> DetailedRoad.Point? in
                guard let lat = point.lat, let lon = point.lon, lat.isFinite, lon.isFinite,
                      (-80...80).contains(lat), (-180...180).contains(lon) else { return nil }
                return DetailedRoad.Point(latitude: lat, longitude: lon)
            }
            guard points.count == geometry.count else { continue }
            vertexCount += points.count
            guard vertexCount <= 80_000 else { throw URLError(.dataLengthExceedsMaximum) }
            result.append(DetailedRoad(id: element.id, points: points, tags: tags,
                nodeIDs: element.nodes?.count == points.count ? element.nodes : nil))
        }
        return result
    }

    private var cacheURL: URL? { storageURL }
    private func restore() {
        guard !restored else { return }
        restored = true
        guard let url = cacheURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 24 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        var vertices = 0
        for entry in entries.sorted(by: { $0.fetchedAt > $1.fetchedAt }) where entry.isUsable {
            guard cache.count < 32, entry.roads.count <= 4_000,
                  entry.roads.allSatisfy({ road in
                      (2...4_000).contains(road.points.count) && road.points.allSatisfy {
                          $0.latitude.isFinite && $0.longitude.isFinite
                              && (-80...80).contains($0.latitude) && (-180...180).contains($0.longitude)
                      }
                  }) else { continue }
            let count = entry.roads.reduce(0) { $0 + $1.points.count }
            guard vertices + count <= 120_000 else { continue }
            vertices += count
            cache[entry.endpoint + "|" + entry.query.id] = entry
        }
    }
    private func trimAndPersist() {
        // Bound both retained geometry and disk usage; old data can still be used during a network outage.
        var entries: [Entry] = []
        var vertices = 0
        for entry in cache.values.filter(\.isUsable).sorted(by: { $0.fetchedAt > $1.fetchedAt }) {
            let count = entry.roads.reduce(0) { $0 + $1.points.count }
            guard entries.count < 32, vertices + count <= 120_000 else { continue }
            vertices += count
            entries.append(entry)
        }
        cache = Dictionary(entries.map { ($0.endpoint + "|" + $0.query.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let url = cacheURL, let data = try? JSONEncoder().encode(entries),
              data.count <= 24 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { logger.debug("Detailed road cache write failed: \(error.localizedDescription, privacy: .private)") }
    }
}
#endif
