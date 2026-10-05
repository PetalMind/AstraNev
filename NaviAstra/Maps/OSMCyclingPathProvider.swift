import Foundation
import OSLog

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

        do {
            try Task.checkCancellation()
            let (data, response) = try await OSMRequestTransport.shared.data(for: request)
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
            return OSMCyclingPathCollection(paths: paths, truncated: truncated)
        } catch {
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
    private var priorityWaiters = 0

    func waitUntilAllowed(priority: Bool = false) async -> Bool {
        if priority { priorityWaiters += 1 }
        defer { if priority { priorityWaiters -= 1 } }
        while true {
            if Task.isCancelled { return false }
            if requestInFlight || (!priority && priorityWaiters > 0) {
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


/// Shared by every Overpass consumer; identical requests share the same download.
actor OSMRequestTransport {
    static let shared = OSMRequestTransport()
    private struct PendingRequest {
        let task: Task<(Data, URLResponse), Error>
        var waiters: Set<UUID>
    }
    private var pending: [String: PendingRequest] = [:]
    private var unavailableUntil: [String: Date] = [:]
    private let logger = Logger(subsystem: "NaviAstra", category: "Overpass")

    func data(for request: URLRequest, priority: Bool = false) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let key = (request.url?.absoluteString ?? "") + "|" + (request.httpMethod ?? "GET")
            + "|" + (request.httpBody?.base64EncodedString() ?? "")
        let waiter = UUID()
        let task: Task<(Data, URLResponse), Error>
        if var existing = pending[key] {
            existing.waiters.insert(waiter)
            pending[key] = existing
            task = existing.task
        } else {
            task = Task { try await self.download(request, priority: priority) }
            pending[key] = PendingRequest(task: task, waiters: [waiter])
        }
        defer { release(key: key, waiter: waiter) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { await self.release(key: key, waiter: waiter) }
        }
    }

    private func release(key: String, waiter: UUID) {
        guard var entry = pending[key], entry.waiters.remove(waiter) != nil else { return }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            pending[key] = nil
        } else { pending[key] = entry }
    }

    private func download(_ request: URLRequest, priority: Bool) async throws -> (Data, URLResponse) {
        var endpoints = [request.url].compactMap { $0 }
        if let fallback = URL(string: "https://overpass.private.coffee/api/interpreter"),
           !endpoints.contains(fallback) { endpoints.append(fallback) }
        var lastError: Error = URLError(.badServerResponse)
        for endpoint in endpoints {
            if let until = unavailableUntil[endpoint.absoluteString], until > .now { continue }
            var candidate = request
            candidate.url = endpoint
            do {
                let result = try await downloadFrom(candidate, priority: priority)
                guard let response = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if response.statusCode == 429 {
                    let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                    unavailableUntil[endpoint.absoluteString] = Date().addingTimeInterval(max(30, delay))
                }
                guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                guard let json = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
                      json["elements"] is [Any], json["remark"] == nil else { throw URLError(.cannotParseResponse) }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
                if let error = error as? URLError, error.code == .notConnectedToInternet { throw error }
            }
        }
        throw lastError
    }

    private func downloadFrom(_ request: URLRequest, priority: Bool) async throws -> (Data, URLResponse) {
        for attempt in 0...1 {
            guard await OSMCyclingRequestGate.shared.waitUntilAllowed(priority: priority) else {
                throw CancellationError()
            }
            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
                await OSMCyclingRequestGate.shared.requestDidFinish()
            } catch {
                await OSMCyclingRequestGate.shared.requestDidFinish()
                logger.error("Overpass host=\(request.url?.host ?? "unknown", privacy: .public) network=\(String(describing: error), privacy: .public)")
                if attempt == 0, let error = error as? URLError,
                   [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                throw error
            }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Overpass host=\(request.url?.host ?? "unknown", privacy: .public) status=\(status) bytes=\(result.0.count)")
            if attempt == 0, [429, 502, 503, 504].contains(status) {
                let header = (result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let delay = max(1, Double(header ?? "") ?? 1)
                // Switch servers instead of repeating against an explicit long cooldown.
                if status == 429 || delay > 5 { return result }
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            return result
        }
        throw URLError(.badServerResponse)
    }
}
