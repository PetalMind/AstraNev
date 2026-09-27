import Foundation
import OSLog

struct TransitousClientConfiguration: Sendable {
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

struct URLSessionTransitousTransport: TransitousTransport {
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

    private let configuration: TransitousClientConfiguration
    private let transport: TransitousTransport
    private let logger = Logger(subsystem: "STDMSolution.NaviAstra", category: "Transitous")
    private let cacheTTL: TimeInterval
    private var cache: [CacheKey: CacheEntry] = [:]
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
