import Foundation

nonisolated struct PlaceRating: Sendable {
    let stars: Double
    let count: Int
    let includesShareAlike: Bool
}

/// Public, read-only Mangrove API. See docs/PLACE_RATINGS.md for matching and licensing.
@MainActor
final class MangrovePlaceRatingProvider {
    static let shared = MangrovePlaceRatingProvider()
    private var cache: [String: (rating: PlaceRating?, date: Date)] = [:]

    func rating(for identity: PlaceIdentity, resolvedOSMID: String?,
                forceRefresh: Bool = false) async throws -> PlaceRating? {
        let subject = try Self.subject(for: identity)
        let key = subject + "/" + (resolvedOSMID ?? "")
        if !forceRefresh, let cached = cache[key], Date().timeIntervalSince(cached.date) < 15 * 60 {
            return cached.rating
        }

        // Fetch all pages before averaging; never present a truncated sample as the total.
        var latest: [String: Review] = [:]
        let pageSize = 200
        for page in 0..<20 {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.mangrove.reviews/reviews")!
            url.queryItems = [
                URLQueryItem(name: "sub", value: subject),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(page * pageSize)),
                URLQueryItem(name: "latest_edits_only", value: "true"),
                URLQueryItem(name: "examples", value: "false")
            ]
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            let reviews = try JSONDecoder().decode(Response.self, from: data).reviews
            for review in reviews where Self.matches(review, identity: identity, resolvedOSMID: resolvedOSMID) {
                let issuer = review.did ?? review.kid
                if let previous = latest[issuer], previous.payload.iat >= review.payload.iat { continue }
                latest[issuer] = review
            }
            if reviews.count < pageSize {
                let values = Array(latest.values)
                let rating = values.isEmpty ? nil : PlaceRating(
                    stars: 1 + values.compactMap { $0.payload.rating }.reduce(0, +) / Double(values.count) / 25,
                    count: values.count,
                    includesShareAlike: values.contains { $0.payload.metadata?.license == "CC-BY-SA-4.0" })
                if cache.count >= 128 { cache.removeAll() }
                cache[key] = (rating, Date())
                return rating
            }
        }
        throw URLError(.dataLengthExceedsMaximum)
    }

    private static func subject(for identity: PlaceIdentity) throws -> String {
        let coordinate = identity.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
              !normalized(identity.name).isEmpty else { throw URLError(.badURL) }
        var uri = URLComponents()
        uri.scheme = "geo"
        uri.path = "\(coordinate.latitude),\(coordinate.longitude)"
        uri.queryItems = [URLQueryItem(name: "q", value: identity.name), URLQueryItem(name: "u", value: "100")]
        guard let subject = uri.string else { throw URLError(.badURL) }
        return subject
    }

    private static func matches(_ review: Review, identity: PlaceIdentity, resolvedOSMID: String?) -> Bool {
        guard let rating = review.payload.rating, rating.isFinite, (0...100).contains(rating),
              review.payload.action == nil,
              let uri = URLComponents(string: review.payload.sub), uri.scheme == "geo" else { return false }
        let coordinates = uri.path.split(separator: ",")
        guard coordinates.count == 2, let latitude = Double(coordinates[0]),
              let longitude = Double(coordinates[1]), latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              identity.coordinate.distance(to: Coordinate(latitude: latitude, longitude: longitude)) <= 100 else { return false }

        let expectedOSMID: String?
        if let resolvedOSMID, resolvedOSMID.hasPrefix("osm/") {
            expectedOSMID = String(resolvedOSMID.dropFirst(4))
        } else if identity.provider == .openStreetMap, let type = identity.osmType, let id = identity.externalID {
            expectedOSMID = "\(type)/\(id)"
        } else {
            expectedOSMID = nil
        }
        if let expectedOSMID, let reviewOSMID = review.payload.metadata?.osm_id {
            // Some clients append the OSM object's version after its type and numeric ID.
            return reviewOSMID.split(separator: "/").prefix(2).joined(separator: "/") == expectedOSMID
        }
        // Mangrove also returns unnamed nearby subjects. Require a matching name locally.
        guard let name = uri.queryItems?.first(where: { $0.name == "q" })?.value else { return false }
        return normalized(name) == normalized(identity.name)
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private struct Response: Decodable { let reviews: [Review] }
    private struct Review: Decodable {
        let kid: String
        let did: String?
        let payload: Payload
    }
    private struct Payload: Decodable {
        let sub: String
        let rating: Double?
        let iat: Double
        let action: String?
        let metadata: Metadata?
    }
    private struct Metadata: Decodable {
        let osm_id: String?
        let license: String?
    }
}
