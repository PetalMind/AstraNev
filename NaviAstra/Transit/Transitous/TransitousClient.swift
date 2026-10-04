import Foundation
import OSLog

nonisolated struct TransitousClientConfiguration: Sendable {
    private static let defaultContact = "dominikjaros99@icloud.com"

    var baseURL = URL(string: "https://api.transitous.org/api/")!
    var applicationName = "NaviAstra"
    var applicationVersion: String
    var contact: String?

    init(baseURL: URL = URL(string: "https://api.transitous.org/api/")!,
         applicationName: String = "NaviAstra",
         applicationVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
         contact: String? = nil) {
        self.baseURL = baseURL
        self.applicationName = applicationName
        self.applicationVersion = applicationVersion
        self.contact = contact
    }

    var userAgent: String? {
        let contact = Self.nonEmpty(contact)
            ?? Self.nonEmpty(UserDefaults.standard.string(forKey: "transitousContact"))
            ?? Self.nonEmpty(Bundle.main.infoDictionary?["TransitousContact"] as? String)
            ?? Self.defaultContact
        guard Self.isValidContact(contact) else { return nil }
        return "\(applicationName)/\(applicationVersion) (\(contact))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isValidContact(_ value: String) -> Bool {
        let components = URLComponents(string: value)
        if components?.scheme?.lowercased() == "https", components?.host != nil {
            return true
        }
        guard !value.contains(where: { $0.isWhitespace }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

protocol TransitousTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransitousTransport: TransitousTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransitRouteError.invalidResponse
        }
        return (data, httpResponse)
    }
}

actor TransitousClient {
    private struct CacheKey: Hashable {
        let originLatitude: Int
        let originLongitude: Int
        let destinationLatitude: Int
        let destinationLongitude: Int
        let time: Int64
        let arriveBy: Bool
        let profile: TransitRouteProfile
        let transferBuffer: Int
        let pedestrianProfile: PedestrianProfile
    }

    private struct CacheEntry {
        let response: TransitousPlanResponseDTO
        let expiresAt: Date
    }

    private struct ValueCache<Value: Sendable> {
        let value: Value
        let expiresAt: Date
    }

    private struct StopSearchKey: Hashable {
        let query: String
        let latitude: Int?
        let longitude: Int?
    }

    private struct MapStopsKey: Hashable {
        let south: Int
        let west: Int
        let north: Int
        let east: Int
    }

    private let configuration: TransitousClientConfiguration
    private let transport: TransitousTransport
    private let logger = Logger(subsystem: "STDMSolution.NaviAstra", category: "Transitous")
    private let cacheTTL: TimeInterval
    private var cache: [CacheKey: CacheEntry] = [:]
    private var stopSearchCache: [StopSearchKey: ValueCache<[TransitousGeocodeMatchDTO]>] = [:]
    private var mapStopsCache: [MapStopsKey: ValueCache<[TransitousPlaceDTO]>] = [:]
    private var stopTimesCache: [String: ValueCache<TransitousStopTimesResponseDTO>] = [:]
    private var tripCache: [String: ValueCache<TransitousItineraryDTO>] = [:]
    private var rateLimitedUntil: Date?

    init(configuration: TransitousClientConfiguration = .init(),
         transport: TransitousTransport = URLSessionTransitousTransport(),
         cacheTTL: TimeInterval = 25) {
        self.configuration = configuration
        self.transport = transport
        self.cacheTTL = max(0, cacheTTL)
    }

    func plan(from origin: Coordinate, to destination: Coordinate, time: Date,
              arriveBy: Bool, preferences: TransitRoutePreferences,
              cancellationToken: TransitPlanningCancellationToken?) async throws
        -> TransitousPlanResponseDTO {
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        guard configuration.userAgent != nil else { throw TransitRouteError.contactRequired }
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            throw TransitRouteError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSinceNow)
        }

        let key = CacheKey(
            originLatitude: Int((origin.latitude * 100_000).rounded()),
            originLongitude: Int((origin.longitude * 100_000).rounded()),
            destinationLatitude: Int((destination.latitude * 100_000).rounded()),
            destinationLongitude: Int((destination.longitude * 100_000).rounded()),
            time: Int64(time.timeIntervalSince1970.rounded()),
            arriveBy: arriveBy,
            profile: preferences.profile,
            transferBuffer: preferences.additionalTransferBufferMinutes,
            pedestrianProfile: preferences.pedestrianProfile)
        if let entry = cache[key], entry.expiresAt > Date() {
            logger.info("Cache hit; journeys=\(entry.response.itineraries.count, privacy: .public)")
            return entry.response
        }
        cache[key] = nil
        cache = cache.filter { $0.value.expiresAt > Date() }
        logger.info("Cache miss")

        let request = try makeRequest(from: origin, to: destination, time: time,
                                      arriveBy: arriveBy, preferences: preferences)
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try cancellationToken?.checkCancellation()
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await perform(request, cancellationToken: cancellationToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw TransitRouteError.timeout
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled || cancellationToken?.isCancelled == true {
                    throw CancellationError()
                }
                throw TransitRouteError.network
            }

            switch response.statusCode {
            case 200...299:
                break
            case 429:
                let retryAfter = Self.retryAfter(from: response) ?? 30
                rateLimitedUntil = Date().addingTimeInterval(max(30, retryAfter))
                logger.error("HTTP 429 rate limited; retryAfter=\(retryAfter, privacy: .public)s")
                throw TransitRouteError.rateLimited(retryAfter: retryAfter)
            case let status where [502, 503, 504].contains(status) && attempt == 0:
                attempt += 1
                logger.warning("HTTP \(response.statusCode, privacy: .public); one bounded retry")
                try await Task.sleep(for: .milliseconds(400))
                continue
            case 500...599:
                logger.error("HTTP \(response.statusCode, privacy: .public)")
                throw TransitRouteError.serviceUnavailable
            default:
                logger.error("Unexpected HTTP \(response.statusCode, privacy: .public)")
                throw TransitRouteError.invalidResponse
            }

            let decodingStartedAt = ProcessInfo.processInfo.systemUptime
            let decoded: TransitousPlanResponseDTO
            do {
                decoded = try JSONDecoder().decode(TransitousPlanResponseDTO.self, from: data)
            } catch {
                logger.error("Response decoding failed")
                throw TransitRouteError.decoding
            }
            let decodingMilliseconds = Int((ProcessInfo.processInfo.systemUptime - decodingStartedAt) * 1_000)
            let requestMilliseconds = Int((ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000)
            logger.info("Request completed in \(requestMilliseconds, privacy: .public)ms; decode=\(decodingMilliseconds, privacy: .public)ms; journeys=\(decoded.itineraries.count, privacy: .public)")
            rateLimitedUntil = nil
            if cache.count >= 128 {
                cache = cache.sorted { $0.value.expiresAt > $1.value.expiresAt }
                    .prefix(96)
                    .reduce(into: [:]) { $0[$1.key] = $1.value }
            }
            cache[key] = CacheEntry(response: decoded, expiresAt: Date().addingTimeInterval(cacheTTL))
            return decoded
        }
    }

    func searchStops(_ query: String, near coordinate: Coordinate?) async throws
        -> [TransitousGeocodeMatchDTO] {
        try Task.checkCancellation()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return [] }
        let key = StopSearchKey(
            query: normalized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            latitude: coordinate.map { Int(($0.latitude * 1_000).rounded()) },
            longitude: coordinate.map { Int(($0.longitude * 1_000).rounded()) })
        if let cached = stopSearchCache[key], cached.expiresAt > Date() { return cached.value }

        var queryItems = [
            URLQueryItem(name: "text", value: normalized),
            URLQueryItem(name: "type", value: "STOP"),
            URLQueryItem(name: "mode", value: "BUS,COACH,TRAM,SUBWAY,RAIL,REGIONAL_RAIL,FERRY"),
            URLQueryItem(name: "language", value: "pl"),
            URLQueryItem(name: "numResults", value: "10")
        ]
        if let coordinate {
            queryItems.append(URLQueryItem(name: "place", value: Self.coordinateParameter(coordinate)))
        }
        let matches: [TransitousGeocodeMatchDTO] = try await get(
            path: ["v1", "geocode"], queryItems: queryItems, timeout: 12)
        stopSearchCache[key] = ValueCache(value: matches, expiresAt: Date().addingTimeInterval(45))
        if stopSearchCache.count > 96 {
            stopSearchCache = stopSearchCache.filter { $0.value.expiresAt > Date() }
        }
        return matches
    }

    func stops(in viewport: TransitMapViewport) async throws -> [TransitousPlaceDTO] {
        try Task.checkCancellation()
        guard viewport.isValid, viewport.zoom >= 13 else { return [] }
        let key = MapStopsKey(south: Int((viewport.south * 10_000).rounded()),
                              west: Int((viewport.west * 10_000).rounded()),
                              north: Int((viewport.north * 10_000).rounded()),
                              east: Int((viewport.east * 10_000).rounded()))
        if let cached = mapStopsCache[key], cached.expiresAt > Date() { return cached.value }

        let modes = ["BUS", "COACH", "TRAM", "SUBWAY", "RAIL", "REGIONAL_RAIL", "FERRY"]
        var queryItems = [
            URLQueryItem(name: "min", value: viewport.apiMinimum),
            URLQueryItem(name: "max", value: viewport.apiMaximum),
            URLQueryItem(name: "grouped", value: "true"),
            URLQueryItem(name: "language", value: "pl")
        ]
        queryItems.append(contentsOf: modes.map { URLQueryItem(name: "modes", value: $0) })
        let stops: [TransitousPlaceDTO] = try await get(
            path: ["v6", "map", "stops"], queryItems: queryItems, timeout: 15)
        mapStopsCache[key] = ValueCache(value: stops, expiresAt: Date().addingTimeInterval(45))
        if mapStopsCache.count > 64 {
            mapStopsCache = mapStopsCache.filter { $0.value.expiresAt > Date() }
        }
        return stops
    }

    func departures(at stopID: String, limit: Int) async throws -> TransitousStopTimesResponseDTO {
        try Task.checkCancellation()
        let normalizedLimit = min(20, max(1, limit))
        let cacheKey = "\(stopID)|\(normalizedLimit)"
        if let cached = stopTimesCache[cacheKey], cached.expiresAt > Date() { return cached.value }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let queryItems = [
            URLQueryItem(name: "stopId", value: stopID),
            URLQueryItem(name: "time", value: formatter.string(from: Date())),
            URLQueryItem(name: "arriveBy", value: "false"),
            URLQueryItem(name: "direction", value: "LATER"),
            URLQueryItem(name: "n", value: String(normalizedLimit)),
            URLQueryItem(name: "realtimeMode", value: "REALTIME"),
            URLQueryItem(name: "withAlerts", value: "true"),
            URLQueryItem(name: "language", value: "pl")
        ]
        let response: TransitousStopTimesResponseDTO = try await get(
            path: ["v6", "stoptimes"], queryItems: queryItems, timeout: 15)
        stopTimesCache[cacheKey] = ValueCache(value: response, expiresAt: Date().addingTimeInterval(12))
        if stopTimesCache.count > 128 {
            stopTimesCache = stopTimesCache.filter { $0.value.expiresAt > Date() }
        }
        return response
    }

    func trip(_ tripID: String) async throws -> TransitousItineraryDTO {
        try Task.checkCancellation()
        if let cached = tripCache[tripID], cached.expiresAt > Date() { return cached.value }
        let queryItems = [
            URLQueryItem(name: "tripId", value: tripID),
            URLQueryItem(name: "withScheduledSkippedStops", value: "true"),
            URLQueryItem(name: "detailedLegs", value: "true"),
            URLQueryItem(name: "joinInterlinedLegs", value: "false"),
            URLQueryItem(name: "language", value: "pl")
        ]
        let response: TransitousItineraryDTO = try await get(
            path: ["v6", "trip"], queryItems: queryItems, timeout: 15)
        tripCache[tripID] = ValueCache(value: response, expiresAt: Date().addingTimeInterval(20))
        if tripCache.count > 128 {
            tripCache = tripCache.filter { $0.value.expiresAt > Date() }
        }
        return response
    }

    private func get<Response: Decodable & Sendable>(path: [String], queryItems: [URLQueryItem],
                                                       timeout: TimeInterval) async throws -> Response {
        try Task.checkCancellation()
        guard configuration.userAgent != nil else { throw TransitRouteError.contactRequired }
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            throw TransitRouteError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSinceNow)
        }
        let request = try makeGET(path: path, queryItems: queryItems, timeout: timeout)
        let responseData: (Data, HTTPURLResponse)
        do {
            responseData = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TransitRouteError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TransitRouteError.network
        }
        let (data, httpResponse) = responseData
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                let retryAfter = Self.retryAfter(from: httpResponse) ?? 30
                rateLimitedUntil = Date().addingTimeInterval(max(30, retryAfter))
                throw TransitRouteError.rateLimited(retryAfter: retryAfter)
            }
            if httpResponse.statusCode >= 500 { throw TransitRouteError.serviceUnavailable }
            throw TransitRouteError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TransitRouteError.decoding
        }
    }

    private func makeGET(path: [String], queryItems: [URLQueryItem], timeout: TimeInterval) throws -> URLRequest {
        guard configuration.baseURL.scheme == "https",
              let userAgent = configuration.userAgent else { throw TransitRouteError.contactRequired }
        let endpoint = path.reduce(configuration.baseURL) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TransitRouteError.invalidResponse
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw TransitRouteError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeRequest(from origin: Coordinate, to destination: Coordinate, time: Date,
                             arriveBy: Bool, preferences: TransitRoutePreferences) throws -> URLRequest {
        guard configuration.baseURL.scheme == "https",
              let userAgent = configuration.userAgent else { throw TransitRouteError.contactRequired }
        let endpoint = configuration.baseURL.appendingPathComponent("v6").appendingPathComponent("plan")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TransitRouteError.invalidResponse
        }
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let queryItems = [
            URLQueryItem(name: "fromPlace", value: Self.coordinateParameter(origin)),
            URLQueryItem(name: "toPlace", value: Self.coordinateParameter(destination)),
            URLQueryItem(name: "time", value: dateFormatter.string(from: time)),
            URLQueryItem(name: "arriveBy", value: String(arriveBy)),
            URLQueryItem(name: "timetableView", value: "true"),
            URLQueryItem(name: "numItineraries", value: "5"),
            URLQueryItem(name: "detailedLegs", value: "true"),
            URLQueryItem(name: "detailedTransfers", value: "true"),
            URLQueryItem(name: "joinInterlinedLegs", value: "false"),
            URLQueryItem(name: "useRoutedTransfers", value: "true"),
            URLQueryItem(name: "transitModes", value: "TRANSIT"),
            URLQueryItem(name: "directModes", value: "WALK"),
            // Avoid Transitous' direct-route cutoff hiding transit journeys slower than a direct walk.
            URLQueryItem(name: "maxDirectTime", value: "0"),
            URLQueryItem(name: "preTransitModes", value: "WALK"),
            URLQueryItem(name: "postTransitModes", value: "WALK"),
            URLQueryItem(name: "additionalTransferTime",
                         value: String(preferences.additionalTransferBufferMinutes)),
            URLQueryItem(name: "pedestrianProfile", value: preferences.pedestrianProfile.rawValue),
            URLQueryItem(name: "language", value: "pl-PL")
        ]
        components.queryItems = queryItems
        guard let url = components.url else { throw TransitRouteError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest,
                         cancellationToken: TransitPlanningCancellationToken?) async throws
        -> (Data, HTTPURLResponse) {
        let requestTask = Task { try await transport.data(for: request) }
        let handlerID = cancellationToken?.addCancellationHandler { requestTask.cancel() }
        defer {
            if let handlerID { cancellationToken?.removeCancellationHandler(handlerID) }
        }
        return try await withTaskCancellationHandler {
            try await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
    }

    private static func coordinateParameter(_ coordinate: Coordinate) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
