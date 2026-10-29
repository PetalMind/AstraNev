import Foundation
import CryptoKit

/// Coalesces nearby/corridor requests and honours server backoff across all callers.
actor TrafficHTTPTransport {
    static let shared = TrafficHTTPTransport()
    private var pending: [String: Task<Data, Error>] = [:]
    private var cache: [String: (data: Data, at: Date)] = [:]
    private var cooldown = Date.distantPast
    private var active = 0

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let credential = request.value(forHTTPHeaderField: "TomTom-Api-Key") ?? ""
        let rawKey = (request.url?.absoluteString ?? "") + credential
        let key = SHA256.hash(data: Data(rawKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let isFlow = request.url?.path.contains("flowSegmentData") == true
        let lifetime: TimeInterval = isFlow ? 30 : 60
        if let cached = cache[key], Date().timeIntervalSince(cached.at) < lifetime { return cached.data }
        if let pending = pending[key] { return try await pending.value }
        let task = Task {
            while active >= 4 { try await Task.sleep(for: .milliseconds(50)) }
            try Task.checkCancellation()
            guard Date() >= cooldown else { throw TrafficError.rateLimited }
            active += 1
            defer { active -= 1 }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TrafficError.invalidResponse }
            if [429, 503].contains(http.statusCode) {
                cooldown = HTTPRetryDelay.date(from: http, minimum: 60)
            }
            guard (200...299).contains(http.statusCode), data.count <= 5_000_000 else {
                throw TrafficError.http(http.statusCode)
            }
            return data
        }
        pending[key] = task
        defer { pending[key] = nil }
        let data = try await task.value
        if cache.count >= 512 { cache.removeAll() }
        cache[key] = (data, Date())
        try Task.checkCancellation()
        return data
    }
}
