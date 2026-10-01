import Foundation
import MapKit

enum PlaceProvider: String, Codable, Sendable {
    case openStreetMap
    case openFreeMap
    case mapKit
}

struct PlaceIdentity {
    let provider: PlaceProvider
    let externalID: String?
    var providerID: String? = nil
    let osmType: String?
    let coordinate: Coordinate
    let name: String
    let category: String?
    let address: String?
    var brand: String? = nil
    var operatorName: String? = nil
    var countryCode: String? = nil
    var timeZoneIdentifier: String? = nil

    var cacheKey: String {
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
        let normalizedCategory = category?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber } ?? ""
        if provider == .openStreetMap, let osmType, let externalID,
           let object = OpenStreetMapObjectID("\(osmType):\(externalID)") {
            return object.cacheKey
        }
        if provider == .mapKit, let providerID, !providerID.isEmpty {
            return "mapkit/\(providerID)"
        }
        if provider == .openFreeMap, let externalID, Int64(externalID) != nil {
            return "openfreemap/osm/\(externalID)/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))"
        }
        return "\(provider.rawValue)/near/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))"
    }
}

struct PlaceDetails: Codable, Identifiable {
    var id: String
    var name: String
    var brand: String?
    var operatorName: String?
    var category: String?
    var address: String?
    var openingHours: String?
    var phone: String?
    var website: String?
    var coordinate: Coordinate? = nil
    var countryCode: String? = nil
    var timeZoneIdentifier: String? = nil
    var imageURL: String? = nil
    var imageAttribution: String? = nil
    var imageLicense: String? = nil
    var wikimediaCommons: String? = nil
    var wikidataID: String? = nil
    var brandWikidataID: String? = nil
    var wheelchair: String?
    var parking: String?
    var osmParking: ParkingInformation?
    var driveThrough: String?
    var internetAccess: String?
    var takeaway: String?
    var delivery: String?
    var outdoorSeating: String?
    var source: PlaceDetailsSource
    var fetchedAt: Date
    var cacheGroupFetchedAt: [String: Date]? = nil

    @MainActor var openingHoursInfo: PlaceOpeningHours? {
        guard let openingHours else { return nil }
        // A POI's local time cannot be safely inferred from the device clock.
        guard coordinate == nil || timeZoneIdentifier != nil else { return nil }
        return PlaceOpeningHours(rawValue: openingHours,
                                 coordinate: coordinate,
                                 countryCode: countryCode,
                                 timeZoneIdentifier: timeZoneIdentifier)
    }

    var websiteURL: URL? {
        guard let website else { return nil }
        let value = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var phoneURL: URL? {
        guard let phone else { return nil }
        let number = phone.filter { $0.isNumber || $0 == "+" }
        guard !number.isEmpty else { return nil }
        return URL(string: "tel:\(number)")
    }

    static func partial(for result: SearchResult) -> PlaceDetails? {
        return PlaceDetails(id: result.placeIdentity.cacheKey,
                            name: result.destination.name,
                            brand: result.brand,
                            operatorName: result.operatorName,
                            category: result.category,
                            address: result.destination.address,
                            openingHours: result.openingHours,
                            phone: result.phone,
                            website: result.website,
                            coordinate: result.destination.coordinate,
                            countryCode: result.countryCode,
                            timeZoneIdentifier: result.timeZoneIdentifier,
                            wheelchair: nil,
                            parking: nil,
                            osmParking: isParkingCategory(result.category) ? .unknown : nil,
                            driveThrough: nil,
                            internetAccess: nil, takeaway: nil, delivery: nil, outdoorSeating: nil,
                            source: result.placeProvider == .mapKit ? .mapKit : result.placeProvider == .openFreeMap ? .openFreeMap : .openStreetMap,
                            fetchedAt: Date())
    }

    static func partial(for identity: PlaceIdentity) -> PlaceDetails {
        PlaceDetails(id: identity.cacheKey,
                     name: identity.name,
                     brand: identity.brand,
                     operatorName: identity.operatorName,
                     category: identity.category,
                     address: identity.address,
                     openingHours: nil,
                     phone: nil,
                     website: nil,
                     coordinate: identity.coordinate,
                     countryCode: identity.countryCode,
                     timeZoneIdentifier: identity.timeZoneIdentifier,
                     wheelchair: nil,
                     parking: nil,
                     osmParking: isParkingCategory(identity.category) ? .unknown : nil,
                     driveThrough: nil,
                     internetAccess: nil, takeaway: nil, delivery: nil, outdoorSeating: nil,
                     source: identity.provider == .mapKit ? .mapKit : identity.provider == .openFreeMap ? .openFreeMap : .openStreetMap,
                     fetchedAt: Date())
    }

    func merging(_ newer: PlaceDetails) -> PlaceDetails {
        PlaceDetails(id: newer.id,
                     name: newer.name.isEmpty ? name : newer.name,
                     brand: newer.brand ?? brand,
                     operatorName: newer.operatorName ?? operatorName,
                     category: newer.category ?? category,
                     address: newer.address ?? address,
                     openingHours: newer.openingHours ?? openingHours,
                     phone: newer.phone ?? phone,
                     website: newer.website ?? website,
                     coordinate: newer.coordinate ?? coordinate,
                     countryCode: newer.countryCode ?? countryCode,
                     timeZoneIdentifier: newer.timeZoneIdentifier ?? timeZoneIdentifier,
                     imageURL: newer.imageURL ?? imageURL,
                     imageAttribution: newer.imageAttribution ?? imageAttribution,
                     imageLicense: newer.imageLicense ?? imageLicense,
                     wikimediaCommons: newer.wikimediaCommons ?? wikimediaCommons,
                     wikidataID: newer.wikidataID ?? wikidataID,
                     brandWikidataID: newer.brandWikidataID ?? brandWikidataID,
                     wheelchair: newer.wheelchair ?? wheelchair,
                     parking: newer.parking ?? parking,
                     osmParking: newer.osmParking ?? osmParking,
                     driveThrough: newer.driveThrough ?? driveThrough,
                     internetAccess: newer.internetAccess ?? internetAccess,
                     takeaway: newer.takeaway ?? takeaway,
                     delivery: newer.delivery ?? delivery,
                     outdoorSeating: newer.outdoorSeating ?? outdoorSeating,
                     source: newer.source,
                     fetchedAt: newer.fetchedAt,
                     cacheGroupFetchedAt: newer.cacheGroupFetchedAt ?? cacheGroupFetchedAt)
    }

    nonisolated var needsCacheRefresh: Bool {
        let groups = cacheGroupFetchedAt ?? Self.legacyCacheGroups(for: self)
        let ttl: [String: TimeInterval] = [
            "identity": 30 * 24 * 60 * 60,
            "contact": 7 * 24 * 60 * 60,
            "hours": 12 * 60 * 60,
            "access": 3 * 24 * 60 * 60
        ]
        let now = Date()
        for (group, lifetime) in ttl {
            guard let fetchedAt = groups[group] else { return true }
            if now.timeIntervalSince(fetchedAt) >= lifetime { return true }
        }
        return false
    }

    nonisolated private static func legacyCacheGroups(for details: PlaceDetails) -> [String: Date] {
        var groups = ["identity": details.fetchedAt]
        if details.phone != nil || details.website != nil { groups["contact"] = details.fetchedAt }
        if details.openingHours != nil { groups["hours"] = details.fetchedAt }
        if details.wheelchair != nil || details.parking != nil || details.osmParking != nil || details.driveThrough != nil ||
            details.internetAccess != nil || details.takeaway != nil || details.delivery != nil || details.outdoorSeating != nil {
            groups["access"] = details.fetchedAt
        }
        return groups
    }

    private static func isParkingCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return category.lowercased().split(separator: "=").last.map(String.init) == "parking"
    }
}

enum PlaceDetailsSource: String, Codable {
    case openStreetMap, mapKit, openFreeMap

    var title: String {
        switch self {
        case .openStreetMap: "OpenStreetMap"
        case .mapKit: "Apple Maps"
        case .openFreeMap: "OpenFreeMap / OpenStreetMap"
        }
    }
}

protocol PlaceDetailsProvider {
    func details(for identity: PlaceIdentity) async throws -> PlaceDetails?
}

/// Refresh Apple POIs by their stable identifier. This also fills contact details omitted
/// by nearby-place results without guessing which branch of a business was selected.
struct MapKitPlaceDetailsProvider: PlaceDetailsProvider {
    func details(for identity: PlaceIdentity) async throws -> PlaceDetails? {
        guard identity.provider == .mapKit, let rawID = identity.providerID,
              let identifier = MKMapItem.Identifier(rawValue: rawID) else { return nil }
        try Task.checkCancellation()
        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        let item = try await withTaskCancellationHandler {
            try await request.mapItem
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        var details = PlaceDetails.partial(for: identity)
        details.name = item.name ?? identity.name
        details.address = item.address?.fullAddress ?? identity.address
        details.category = item.pointOfInterestCategory?.rawValue ?? identity.category
        details.phone = item.phoneNumber
        details.website = item.url?.absoluteString
        details.timeZoneIdentifier = item.timeZone?.identifier ?? identity.timeZoneIdentifier
        details.countryCode = item.addressRepresentations?.region?.identifier.lowercased() ?? identity.countryCode
        return details
    }
}

struct OpenStreetMapPlaceDetailsProvider: PlaceDetailsProvider {
    private var endpoint: URL {
        if let configured = UserDefaults.standard.string(forKey: "overpassServer"),
           let url = URL(string: configured),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return url
        }
        return URL(string: "https://overpass-api.de/api/interpreter")!
    }
    private static let fallbackEndpoints = [
        "https://overpass.private.coffee/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
    ].compactMap { URL(string: $0) }

    private var requestEndpoints: [URL] {
        var seen = Set<String>()
        return ([endpoint] + Self.fallbackEndpoints).filter { seen.insert($0.absoluteString).inserted }
    }

    /// Search responses already contain full OSM tags; reuse them instead of fetching the same object again.
    static func maintainCache() async {
        await PlaceDetailsCache.shared.maintain()
    }

    static func cacheSearchDetails(_ objects: [(id: String, name: String, tags: [String: String])]) async {
        let details = objects.compactMap { object -> PlaceDetails? in
            guard let id = OpenStreetMapObjectID(object.id) else { return nil }
            return makeDetails(id: id.cacheKey, fallbackName: object.name, tags: object.tags)
        }
        await PlaceDetailsCache.shared.store(details)
    }

    func cachedDetails(for identity: PlaceIdentity) async -> PlaceDetails? {
        await PlaceDetailsCache.shared.value(for: identity.cacheKey, allowExpired: true)
    }

    func details(for identity: PlaceIdentity) async throws -> PlaceDetails? {
        try await details(for: identity, forceRefresh: false)
    }

    func details(for identity: PlaceIdentity, forceRefresh: Bool) async throws -> PlaceDetails? {
        try Task.checkCancellation()
        let value = try await PlaceDetailsRequests.load(
            key: endpoint.absoluteString + "/" + identity.cacheKey,
            forceRefresh: forceRefresh
        ) {
            try await fetchDetails(for: identity, forceRefresh: forceRefresh)
        }
        try Task.checkCancellation()
        return value
    }

    private func fetchDetails(for identity: PlaceIdentity, forceRefresh: Bool) async throws -> PlaceDetails? {
        let partial = PlaceDetails.partial(for: identity)
        let requestedID: OpenStreetMapObjectID?
        if identity.provider == .openStreetMap,
           let osmType = identity.osmType, let externalID = identity.externalID {
            requestedID = OpenStreetMapObjectID("\(osmType):\(externalID)")
        } else {
            requestedID = nil
        }
        let requestKey = identity.cacheKey
        if !forceRefresh, let cached = await PlaceDetailsCache.shared.value(for: requestKey) {
            return partial.merging(cached)
        }

        let selector: String
        if let requestedID {
            selector = "\(requestedID.selector);"
        } else {
            selector = "nwr(around:100,\(identity.coordinate.latitude),\(identity.coordinate.longitude))[~\"^(name(:.*)?|brand|operator)$\"~\".\"];"
        }
        let query = "[out:json][timeout:6];\(selector)out center tags;"
        var receivedValidResponse = false
        for (attempt, requestEndpoint) in requestEndpoints.enumerated() {
            try Task.checkCancellation()
            do {
                let reply = try await fetchReply(query: query, from: requestEndpoint,
                                                 timeout: attempt == 0 ? 8 : 6)
                guard reply.remark == nil else { throw PlaceDetailsError.unavailable }
                receivedValidResponse = true

                let element: Element?
                if let requestedID {
                    element = reply.elements.first(where: { $0.type == requestedID.type && $0.id == requestedID.value })
                } else {
                    let candidates = reply.elements.compactMap { candidate -> (element: Element, score: Double)? in
                        guard let tags = candidate.tags,
                              let coordinate = candidate.coordinate else { return nil }
                        let distance = coordinate.distance(to: identity.coordinate)
                        if identity.provider == .openFreeMap, let externalID = identity.externalID {
                            let categoryMatch = identity.category.map { Self.matchesCategory($0, tags: tags) } ?? false
                            guard let tileID = Int64(externalID), tileID != Int64.min,
                                  (candidate.id == tileID || candidate.id == abs(tileID)),
                                  Self.matchesExactName(Self.normalized(identity.name), tags: tags) || categoryMatch,
                                  distance <= 100 else { return nil }
                            let categoryScore = categoryMatch ? 180.0 : 0
                            return (candidate, 1_500 + categoryScore - distance)
                        }

                        guard distance <= 100,
                              !Self.hasConflictingAddress(identity.address, tags: tags),
                              let nameScore = Self.nameMatchScore(identity, tags: tags),
                              nameScore >= 400 else { return nil }
                        let categoryMatch = identity.category.map { Self.matchesCategory($0, tags: tags) } ?? false
                        let addressMatch = Self.addressMatchScore(identity.address, tags: tags)
                        guard distance <= 40 || nameScore >= 760 || categoryMatch || addressMatch >= 100 else { return nil }
                        let score = nameScore + (categoryMatch ? 180 : 0) + addressMatch - distance * 2
                        return (candidate, score)
                    }
                    element = candidates.max { $0.score < $1.score }?.element
                }
                guard let element, let tags = element.tags,
                      let resolvedID = OpenStreetMapObjectID("\(element.type):\(element.id)") else { continue }
                let resolvedKey = resolvedID.cacheKey
                let downloaded = Self.makeDetails(id: resolvedKey, fallbackName: partial.name, tags: tags)
                await PlaceDetailsCache.shared.store(downloaded, for: Array(Set([resolvedKey, requestKey])))
                return partial.merging(downloaded)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Try the next public instance after a timeout, rate limit, or malformed response.
            }
        }
        if receivedValidResponse { return nil }
        throw PlaceDetailsError.unavailable
    }

    private func fetchReply(query: String, from endpoint: URL, timeout: TimeInterval) async throws -> Reply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra/1.0 (https://github.com/PetalMind/AstraNev; OpenStreetMap place details)",
                         forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaceDetailsError.unavailable
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw PlaceDetailsError.invalidResponse
        }
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func matchesExactName(_ expected: String, tags: [String: String]) -> Bool {
        guard !expected.isEmpty else { return false }
        let taggedNames = [tags["name"], tags["brand"], tags["operator"]].compactMap { $0 }
            + tags.filter { $0.key.lowercased().hasPrefix("name:") }.map(\.value)
        for value in taggedNames {
            if normalized(value) == expected { return true }
        }
        return false
    }

    private static func matchesCategory(_ expected: String, tags: [String: String]) -> Bool {
        let rawCategory = expected.split(separator: "=").last.map(String.init) ?? expected
        var aliases = [normalized(rawCategory)]
        let mapKitPrefix = "mkpoicategory"
        let normalizedCategory = normalized(expected)
        if normalizedCategory.hasPrefix(mapKitPrefix) {
            aliases.append(String(normalizedCategory.dropFirst(mapKitPrefix.count)))
        }
        if aliases.contains(where: { ["chargingstation", "evcharger", "evcharging"].contains($0) }) {
            aliases.append(contentsOf: ["chargingstation", "evcharger", "evcharging"])
        }
        aliases = aliases.filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        return tags.keys.contains(where: { aliases.contains(normalized($0)) }) ||
            tags.values.contains(where: { aliases.contains(normalized($0)) })
    }

    private static func nameMatchScore(_ identity: PlaceIdentity, tags: [String: String]) -> Double? {
        let taggedNames = ([tags["name"], tags["brand"], tags["operator"]].compactMap { $0 }
            + tags.filter { $0.key.lowercased().hasPrefix("name:") }.map(\.value)).map(normalized)
        guard !taggedNames.isEmpty else { return nil }
        let expected = [identity.name, identity.brand, identity.operatorName]
            .compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
        guard !expected.isEmpty else { return nil }

        var best = 0.0
        for (index, value) in expected.enumerated() {
            for tagged in taggedNames where tagged == value {
                let weight = index == 0 ? 1_000.0 : index == 1 ? 760.0 : 620.0
                best = max(best, weight)
            }
        }
        if best > 0 { return best }

        // Small spelling or punctuation differences are acceptable only with enough shared name tokens.
        let target = expected[0]
        for tagged in taggedNames {
            let shorter = min(target.count, tagged.count)
            if shorter >= 6 && (target.contains(tagged) || tagged.contains(target)) {
                best = max(best, 520)
            }
        }
        return best > 0 ? best : nil
    }

    private static func addressMatchScore(_ expected: String?, tags: [String: String]) -> Double {
        guard let expected else { return 0 }
        let expectedValue = normalized(expected)
        guard !expectedValue.isEmpty else { return 0 }
        let taggedAddress = [tags["addr:full"], tags["addr:street"], tags["addr:housenumber"],
                             tags["addr:suburb"], tags["addr:postcode"], tags["addr:city"], tags["addr:place"]]
            .compactMap { $0 }.joined(separator: " ")
        let actualValue = normalized(taggedAddress)
        guard !actualValue.isEmpty else { return 0 }
        if expectedValue.contains(actualValue) || actualValue.contains(expectedValue) { return 220 }
        let expectedTokens = Set(expected.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) })
        let actualTokens = Set(taggedAddress.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) })
        guard !expectedTokens.isEmpty else { return 0 }
        return Double(expectedTokens.intersection(actualTokens).count) / Double(expectedTokens.count) * 120
    }

    private static func hasConflictingAddress(_ expected: String?, tags: [String: String]) -> Bool {
        guard let expected, let expectedNumber = PhotonSearchProvider.houseNumber(in: expected),
              let actualNumber = tags["addr:housenumber"].map(PhotonSearchProvider.normalized) else { return false }
        return expectedNumber != actualNumber
    }

    private static func makeDetails(id: String, fallbackName: String, tags: [String: String]) -> PlaceDetails {
        let streetLine = [tags["addr:street"], tags["addr:housenumber"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [tags["addr:postcode"], tags["addr:city"] ?? tags["addr:place"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let structuredAddress = [streetLine.isEmpty ? nil : streetLine,
                                 tags["addr:suburb"],
                                 locality.isEmpty ? nil : locality]
            .compactMap { $0 }
            .joined(separator: ", ")
        let address = tags["addr:full"] ?? (structuredAddress.isEmpty ? nil : structuredAddress)
        let category = ["amenity", "shop", "tourism", "leisure", "office", "craft", "historic"]
            .compactMap { tags[$0] }
            .first

        let name = tags["name"] ?? tags["brand"] ?? fallbackName
        let phone = tags["contact:phone"] ?? tags["phone"]
        let website = tags["contact:website"] ?? tags["website"]
        let imageURL = tags["image"]
        let imageAttribution = tags["image:attribution"]
        let imageLicense = tags["image:license"]
        let wikimediaCommons = tags["wikimedia_commons"]
        let wikidataID = tags["wikidata"]
        let brandWikidataID = [tags["brand:wikidata"], tags["operator:wikidata"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { identifiers, value in
                if !identifiers.contains(value) { identifiers.append(value) }
            }
            .joined(separator: ";")
        let wheelchair = tags["wheelchair"]
        let parking = tags["parking"]
        let driveThrough = tags["drive_through"]
        let internetAccess = tags["internet_access"]
        let takeaway = tags["takeaway"]
        let delivery = tags["delivery"]
        let outdoorSeating = tags["outdoor_seating"]
        let osmParking = ParkingInformation.fromOSMTags(tags)
        let now = Date()
        // Record negative lookups too, so missing fields are retried after their TTL.
        let cacheGroupFetchedAt = ["identity": now, "contact": now, "hours": now, "access": now]

        return PlaceDetails(id: id,
                            name: name,
                            brand: tags["brand"],
                            operatorName: tags["operator"],
                            category: category,
                            address: address,
                            openingHours: tags["opening_hours"],
                            phone: phone,
                            website: website,
                            coordinate: nil,
                            countryCode: countryCode(from: tags),
                            timeZoneIdentifier: nil,
                            imageURL: imageURL,
                            imageAttribution: imageAttribution,
                            imageLicense: imageLicense,
                            wikimediaCommons: wikimediaCommons,
                            wikidataID: wikidataID,
                            brandWikidataID: brandWikidataID,
                            wheelchair: wheelchair,
                            parking: parking,
                            osmParking: osmParking,
                            driveThrough: driveThrough,
                            internetAccess: internetAccess,
                            takeaway: takeaway,
                            delivery: delivery,
                            outdoorSeating: outdoorSeating,
                            source: .openStreetMap,
                            fetchedAt: now,
                            cacheGroupFetchedAt: cacheGroupFetchedAt)
    }

    private static func countryCode(from tags: [String: String]) -> String? {
        guard let value = tags["addr:country"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 2, value.allSatisfy(\.isLetter) else { return nil }
        return value.lowercased()
    }

    private struct Reply: Decodable { let elements: [Element]; let remark: String? }
    private struct Element: Decodable {
        let id: Int64
        let type: String
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
        var coordinate: Coordinate? {
            guard let latitude = lat ?? center?.lat, let longitude = lon ?? center?.lon,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return Coordinate(latitude: latitude, longitude: longitude)
        }
    }
    private struct Center: Decodable { let lat: Double; let lon: Double }
}

enum PlaceDetailsError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Szczegóły miejsca z OpenStreetMap są chwilowo niedostępne."
        case .invalidResponse: "Usługa szczegółów miejsca zwróciła nieprawidłowe dane."
        }
    }
}

nonisolated struct OpenStreetMapObjectID {
    let type: String
    let value: Int64

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 2, let value = Int64(parts[1]), value > 0 else { return nil }
        let type: String
        switch parts[0].lowercased() {
        case "n", "node": type = "node"
        case "w", "way": type = "way"
        case "r", "relation": type = "relation"
        default: return nil
        }
        self.type = type
        self.value = value
    }

    var cacheKey: String { "osm/\(type)/\(value)" }
    var selector: String { "\(type)(\(value))" }
}

/// Shared requests survive a card being collapsed, so reopening it reuses the same download.
@MainActor
private enum PlaceDetailsRequests {
    static var pending: [String: Task<PlaceDetails?, Error>] = [:]
    static var missingUntil: [String: Date] = [:]

    static func load(key: String, forceRefresh: Bool = false,
                     operation: @escaping @MainActor () async throws -> PlaceDetails?) async throws -> PlaceDetails? {
        if let pending = pending[key] { return try await pending.value }
        if forceRefresh {
            missingUntil[key] = nil
        } else if let until = missingUntil[key], until > Date() {
            return nil
        }
        let task = Task { try await operation() }
        pending[key] = task
        defer { pending[key] = nil }
        let value = try await task.value
        if value == nil {
            missingUntil = missingUntil.filter { $0.value > Date() }
            if missingUntil.count >= 200 { missingUntil.removeAll() }
            missingUntil[key] = Date().addingTimeInterval(300)
        }
        return value
    }
}

private actor PlaceDetailsCache {
    static let shared = PlaceDetailsCache()
    private let fileURL: URL
    private var entries: [String: PlaceDetails] = [:]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        fileURL = directory.appendingPathComponent("place-details-cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: PlaceDetails].self, from: data) {
            entries = stored
        }
    }

    func value(for id: String, allowExpired: Bool = false) -> PlaceDetails? {
        guard let entry = entries[id] else { return nil }
        // Keep stale information available while the card refreshes it. Cache misses do no disk IO.
        guard allowExpired || !entry.needsCacheRefresh else { return nil }
        return entry
    }

    func store(_ details: PlaceDetails, for ids: [String]) {
        for id in ids { entries[id] = details }
        if entries.count > 1_000 {
            let newestEntries = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(1_000)
                .map { ($0.key, $0.value) }
            entries = Dictionary(uniqueKeysWithValues: newestEntries)
        }
        persist()
    }

    func store(_ details: [PlaceDetails]) {
        guard !details.isEmpty else { return }
        for detail in details { entries[detail.id] = detail }
        if entries.count > 1_000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(1_000).map { ($0.key, $0.value) })
        }
        persist()
    }

    func maintain() {
        guard !Task.isCancelled else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        entries = entries.filter { $0.value.fetchedAt >= cutoff }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache write failure must not hide details that were just fetched.
        }
    }
}
