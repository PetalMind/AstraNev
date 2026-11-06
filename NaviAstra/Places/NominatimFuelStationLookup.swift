import Foundation

/// Narrow lookup of already identified OSM stations, never a geocoder or search.
/// Public-service traffic is serialized; deployments with multiple users should
/// configure their own endpoint/proxy through `nominatimLookupServer`.
@MainActor
enum NominatimFuelStationLookup {
    struct Record: Decodable, Equatable {
        let osmType: String
        let osmID: Int64
        let latitude: String
        let longitude: String
        let category: String?
        let type: String
        let name: String?
        let address: [String: String]?
        let extraTags: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case osmType = "osm_type", osmID = "osm_id", latitude = "lat", longitude = "lon"
            case category, legacyCategory = "class", type, name, address, extraTags = "extratags"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            osmType = try values.decode(String.self, forKey: .osmType)
            osmID = try values.decode(Int64.self, forKey: .osmID)
            latitude = try values.decode(String.self, forKey: .latitude)
            longitude = try values.decode(String.self, forKey: .longitude)
            category = try values.decodeIfPresent(String.self, forKey: .category)
                ?? values.decodeIfPresent(String.self, forKey: .legacyCategory)
            type = try values.decode(String.self, forKey: .type)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            address = try values.decodeIfPresent([String: String].self, forKey: .address)
            extraTags = try values.decodeIfPresent([String: String].self, forKey: .extraTags)
        }

        var object: OpenStreetMapObjectID? { OpenStreetMapObjectID("\(osmType):\(osmID)") }

        var coordinate: Coordinate? {
            guard let lat = Double(latitude), let lon = Double(longitude), lat.isFinite, lon.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return Coordinate(latitude: lat, longitude: lon)
        }

        func tags(for identity: PlaceIdentity) -> [String: String]? {
            guard let expected = NominatimFuelStationLookup.object(for: identity),
                  object?.cacheKey == expected.cacheKey, category == "amenity", type == "fuel",
                  let coordinate, coordinate.distance(to: identity.coordinate) <= 150 else { return nil }
            var tags = extraTags ?? [:]
            tags["amenity"] = "fuel"
            if let name, !name.isEmpty { tags["name"] = name }
            let mappings = ["road": "addr:street", "house_number": "addr:housenumber",
                "postcode": "addr:postcode", "country_code": "addr:country"]
            for (field, tag) in mappings {
                if let value = address?[field], !value.isEmpty { tags[tag] = value }
            }
            tags["addr:city"] = address?["city"] ?? address?["town"] ?? address?["village"] ?? tags["addr:city"]
            let actual = [tags["addr:street"], tags["addr:housenumber"]].compactMap { $0 }.joined(separator: " ")
            guard !PlaceAddressMatching.hasStreetConflict(identity.address, actual: actual) else { return nil }
            if let address = identity.address, let expectedNumber = PhotonSearchProvider.houseNumber(in: address),
               let actualNumber = tags["addr:housenumber"].map(PhotonSearchProvider.normalized),
               expectedNumber != actualNumber { return nil }
            return tags
        }
    }

    struct Reply {
        let records: [Record]
        let fetchedAt: Date
    }

    private static var inFlight = false
    private static var nextRequestAt = Date.distantPast
    private static var cooldowns: [String: Date] = [:]

    static func object(for identity: PlaceIdentity) -> OpenStreetMapObjectID? {
        guard identity.provider == .openStreetMap,
              PaliwoMapaFuelPriceProvider.isFuelStation(category: identity.category),
              let type = identity.osmType, let id = identity.externalID else { return nil }
        return OpenStreetMapObjectID("\(type):\(id)")
    }

    static func records(_ records: [Record], matching identity: PlaceIdentity) -> Record? {
        guard let object = object(for: identity) else { return nil }
        let matching = records.filter { $0.object?.cacheKey == object.cacheKey }
        guard let first = matching.first, matching.allSatisfy({ record in
            // Nominatim may repeat a POI with a shorter address. Identical hours
            // and coordinates can be deduplicated; contradictory facts cannot.
            record.tags(for: identity) != nil && record.extraTags?["opening_hours"] == first.extraTags?["opening_hours"] &&
                Double(record.latitude) == Double(first.latitude) && Double(record.longitude) == Double(first.longitude)
        }) else { return nil }
        return matching.max { ($0.address?.count ?? 0) < ($1.address?.count ?? 0) }
    }

    static func lookup(_ identities: [PlaceIdentity]) async throws -> Reply {
        let objects = identities.compactMap(object(for:))
        let ids = Array(Set(objects.map { object in
            let prefix = object.type == "node" ? "N" : object.type == "way" ? "W" : "R"
            return "\(prefix)\(object.value)"
        })).sorted().prefix(8)
        guard !ids.isEmpty else { return Reply(records: [], fetchedAt: Date()) }
        let configured = UserDefaults.standard.string(forKey: "nominatimLookupServer")
        let endpoint = configured.flatMap(URL.init(string:))
            ?? URL(string: "https://nominatim.openstreetmap.org/lookup")!
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host,
              endpoint.user == nil, endpoint.password == nil,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw PlaceDetailsError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "osm_ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "format", value: "jsonv2"), URLQueryItem(name: "extratags", value: "1"),
            URLQueryItem(name: "addressdetails", value: "1"), URLQueryItem(name: "accept-language", value: "pl")]
        guard let url = components.url else { throw PlaceDetailsError.invalidResponse }
        let deadline = Date().addingTimeInterval(5)
        while inFlight || Date() < nextRequestAt {
            try Task.checkCancellation()
            guard Date() < deadline else { throw PlaceDetailsError.unavailable }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard (cooldowns[host] ?? .distantPast) <= Date() else { throw PlaceDetailsError.unavailable }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.1 else { throw PlaceDetailsError.unavailable }
        inFlight = true
        nextRequestAt = Date().addingTimeInterval(1.1)
        defer { inFlight = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remaining
        configuration.timeoutIntervalForResource = remaining
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: remaining)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("pl", forHTTPHeaderField: "Accept-Language")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("NaviAstra/\(version) (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw PlaceDetailsError.invalidResponse }
            if [403, 429, 503].contains(http.statusCode) {
                cooldowns[host] = HTTPRetryDelay.date(from: http, minimum: http.statusCode == 403 ? 3_600 : 60)
            }
            guard (200..<300).contains(http.statusCode), data.count <= 1_048_576 else { throw PlaceDetailsError.unavailable }
            let records = try JSONDecoder().decode([Record].self, from: data)
            return Reply(records: records, fetchedAt: Date())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            cooldowns[host] = max(cooldowns[host] ?? .distantPast, Date().addingTimeInterval(30))
            throw error
        }
    }
}
