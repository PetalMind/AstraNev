import Foundation

/// Optional, explicitly configured self-hosted service. No default cloud account.
@MainActor
enum SharedRoadReportsClient {
    static var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RoadReportsServerURL") as? String,
              !value.contains("$("), let url = WebsiteOpeningHoursProvider.safeURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return url
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()
    private static var cached: [String: (reports: [LocalRoadReport], fetchedAt: Date)] = [:]
    private static var cooldown = Date.distantPast
    private static var pending: [String: Task<[LocalRoadReport], Error>] = [:]
    private static var generation = 0

    static func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] {
        guard let endpoint else { return [] }
        guard !boxes.isEmpty else { return [] }
        guard Date() >= cooldown else { throw RoadReportError.server }
        // One bounding rectangle, not a stream of precise GPS positions.
        let target = TrafficBoundingBox(minLongitude: boxes.map(\.minLongitude).min()!, minLatitude: boxes.map(\.minLatitude).min()!,
                                        maxLongitude: boxes.map(\.maxLongitude).max()!, maxLatitude: boxes.map(\.maxLatitude).max()!)
        let box = TrafficBoundingBox(minLongitude: floor(target.minLongitude * 20) / 20,
                                    minLatitude: floor(target.minLatitude * 20) / 20,
                                    maxLongitude: ceil(target.maxLongitude * 20) / 20,
                                    maxLatitude: ceil(target.maxLatitude * 20) / 20)
        let key = box.queryValue
        if let cached = cached[key], Date().timeIntervalSince(cached.fetchedAt) <= 60 {
            return cached.reports.filter { LocalRoadReportStore.valid($0, at: Date()) && target.contains($0.coordinate) }.map { $0.incident(source: .community) }
        }
        let task: Task<[LocalRoadReport], Error>
        if let existing = pending[key] { task = existing }
        else {
            let startedGeneration = generation
            task = Task { @MainActor in
                var url = URLComponents(url: endpoint.appendingPathComponent("reports"), resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "bbox", value: key)]
                var request = URLRequest(url: url.url!)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let data = try await download(request)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let response = try? decoder.decode(Response.self, from: data), response.reports.count <= 200 else { throw RoadReportError.server }
                let reports = response.reports.filter { LocalRoadReportStore.valid($0, at: Date()) && box.contains($0.coordinate) }
                if cached.count >= 32 { cached.removeAll() }
                if startedGeneration == generation { cached[key] = (reports, Date()) }
                return reports
            }
            pending[key] = task
        }
        defer { pending[key] = nil }
        let reports = try await task.value
        try Task.checkCancellation()
        return reports.filter { target.contains($0.coordinate) }.map { $0.incident(source: .community) }
    }

    /// Called only by the explicit "Udostępnij" action in the report form.
    static func publish(_ report: LocalRoadReport) async throws {
        guard let endpoint, LocalRoadReportStore.valid(report, at: Date()) else { throw RoadReportError.server }
        var request = URLRequest(url: endpoint.appendingPathComponent("reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        // Limit a shared point's precision; never send a trace, device ID or identity.
        let shared = LocalRoadReport(id: report.id, kind: report.kind,
            coordinate: Coordinate(latitude: (report.coordinate.latitude * 1_000).rounded() / 1_000,
                                   longitude: (report.coordinate.longitude * 1_000).rounded() / 1_000),
            createdAt: report.createdAt, expiresAt: report.expiresAt)
        request.httpBody = try encoder.encode(shared)
        _ = try await download(request)
        generation += 1
        cached.removeAll()
    }

    private static func download(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RoadReportError.server }
            if [429, 503].contains(http.statusCode) { cooldown = HTTPRetryDelay.date(from: http, minimum: 60) }
            guard (200...299).contains(http.statusCode), data.count <= 300_000 else { throw RoadReportError.server }
            return data
        } catch { throw RoadReportError.server }
    }
    private struct Response: Decodable { let reports: [LocalRoadReport] }
}
