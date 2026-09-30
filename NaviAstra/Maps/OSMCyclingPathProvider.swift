import Foundation

nonisolated struct OSMCyclingPath: Identifiable, Sendable {
    let id: Int64
    let coordinates: [Coordinate]
}

nonisolated struct OSMCyclingPathCollection: Sendable {
    let paths: [OSMCyclingPath]
    let truncated: Bool
}

nonisolated enum OSMCyclingPathsStatus: Equatable, Sendable {
    case disabled
    case zoomIn
    case loading
    case loaded(count: Int, truncated: Bool)
    case unavailable
}

nonisolated struct OSMCyclingQuery: Hashable, Sendable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    var id: String {
        [south, west, north, east]
            .map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",") + "|" + OSMCyclingEndpoint.url.absoluteString
    }

    var overpassQL: String {
        let bounds = [south, west, north, east]
            .map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), arguments: [$0]) }
            .joined(separator: ",")
        return """
        [out:json][timeout:25];
        (
          way["highway"="cycleway"](\(bounds));
          way["highway"="path"]["bicycle"="designated"](\(bounds));
        );
        out geom;
        """
    }

    static func visible(center: Coordinate, latitudeDelta: Double,
                        longitudeDelta: Double) -> OSMCyclingQuery? {
        guard center.latitude.isFinite, center.longitude.isFinite,
              latitudeDelta.isFinite, longitudeDelta.isFinite,
              latitudeDelta > 0, longitudeDelta > 0,
              latitudeDelta <= 0.25, longitudeDelta <= 0.35 else { return nil }

        let step = 0.025
        let halfLatitude = latitudeDelta / 2
        let halfLongitude = longitudeDelta / 2
        let south = max(-90, floor((center.latitude - halfLatitude) / step) * step)
        let north = min(90, ceil((center.latitude + halfLatitude) / step) * step)
        let west = max(-180, floor((center.longitude - halfLongitude) / step) * step)
        let east = min(180, ceil((center.longitude + halfLongitude) / step) * step)
        guard north > south, east > west else { return nil }
        return OSMCyclingQuery(south: south, west: west, north: north, east: east)
    }
}

actor OSMCyclingPathProvider {
    static let shared = OSMCyclingPathProvider()

    private struct CacheEntry {
        let paths: OSMCyclingPathCollection
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<OSMCyclingPathCollection, Error>] = [:]

    func paths(in query: OSMCyclingQuery) async throws -> OSMCyclingPathCollection {
        if let entry = cache[query.id], Date().timeIntervalSince(entry.fetchedAt) < 30 * 60 {
            return entry.paths
        }
        if let task = inFlight[query.id] { return try await task.value }

        let task = Task { try await Self.download(query) }
        inFlight[query.id] = task
        do {
            let paths = try await task.value
            cache[query.id] = CacheEntry(paths: paths, fetchedAt: Date())
            inFlight[query.id] = nil
            trimCacheIfNeeded()
            return paths
        } catch {
            inFlight[query.id] = nil
            throw error
        }
    }

    private func trimCacheIfNeeded() {
        guard cache.count > 64 else { return }
        let oldestKeys = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(cache.count - 64)
            .map(\.key)
        oldestKeys.forEach { cache[$0] = nil }
    }

    private static func download(_ query: OSMCyclingQuery) async throws -> OSMCyclingPathCollection {
        var request = URLRequest(url: OSMCyclingEndpoint.url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NaviAstra", forHTTPHeaderField: "User-Agent")
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
                throw OSMCyclingPathError.unavailable
            }
            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
            let ways = decoded.elements.filter { $0.type == "way" }
            let truncated = ways.count > 3_000
            let paths = ways.prefix(3_000).compactMap { element -> OSMCyclingPath? in
                guard let geometry = element.geometry else { return nil }
                let coordinates = geometry.compactMap { point -> Coordinate? in
                    guard point.lat.isFinite, point.lon.isFinite,
                          (-90...90).contains(point.lat), (-180...180).contains(point.lon) else { return nil }
                    return Coordinate(latitude: point.lat, longitude: point.lon)
                }
                guard coordinates.count > 1 else { return nil }
                return OSMCyclingPath(id: element.id, coordinates: coordinates)
            }
            await OSMCyclingRequestGate.shared.requestDidFinish()
            return OSMCyclingPathCollection(paths: paths, truncated: truncated)
        } catch {
            await OSMCyclingRequestGate.shared.requestDidFinish()
            throw error
        }
    }
}

nonisolated private enum OSMCyclingEndpoint {
    static var url: URL {
        let configured = UserDefaults.standard.string(forKey: "overpassServer")
        return configured.flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
            ?? URL(string: "https://overpass-api.de/api/interpreter")!
    }
}

actor OSMCyclingRequestGate {
    static let shared = OSMCyclingRequestGate()
    private var lastRequestStartedAt: Date?
    private var requestInFlight = false

    func waitUntilAllowed() async -> Bool {
        while true {
            if requestInFlight {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return false }
                continue
            }
            if let lastRequestStartedAt {
                let delay = 1.1 - Date().timeIntervalSince(lastRequestStartedAt)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { return false }
                    continue
                }
            }
            lastRequestStartedAt = Date()
            requestInFlight = true
            return true
        }
    }

    func requestDidFinish() {
        requestInFlight = false
    }
}

nonisolated private enum OSMCyclingPathError: Error {
    case unavailable
}

nonisolated private struct OverpassResponse: Decodable {
    let elements: [Element]

    nonisolated struct Element: Decodable {
        let type: String
        let id: Int64
        let geometry: [Point]?
    }

    nonisolated struct Point: Decodable {
        let lat: Double
        let lon: Double
    }
}
