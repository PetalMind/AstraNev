import Foundation
import MapKit
import OSLog

enum PlaceProvider: String, Codable, Sendable {
    case openStreetMap
    case openFreeMap
    case mapKit
    case inPost

    var detailsSource: PlaceDetailsSource {
        switch self {
        case .openStreetMap: .openStreetMap
        case .openFreeMap: .openFreeMap
        case .mapKit: .mapKit
        case .inPost: .inPost
        }
    }
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
        if provider == .inPost, let providerID { return "inpost/\(providerID.uppercased())" }
        // One OSM shop may also provide parcel pickup with a different carrier and schedule.
        let serviceSuffix = category == "parcel_pickup" ? "/parcel-pickup" : ""
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
        let normalizedCategory = category?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber } ?? ""
        if provider == .openStreetMap, let osmType, let externalID,
           let object = OpenStreetMapObjectID("\(osmType):\(externalID)") {
            return object.cacheKey + serviceSuffix
        }
        if provider == .mapKit, let providerID, !providerID.isEmpty {
            return "mapkit/\(providerID)" + serviceSuffix
        }
        if provider == .openFreeMap, let externalID, Int64(externalID) != nil {
            return "openfreemap/osm/\(externalID)/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))" + serviceSuffix
        }
        return "\(provider.rawValue)/near/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))" + serviceSuffix
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
    var openingHoursURL: String? = nil
    var supplementalSource: PlaceSupplementalSource? = nil
    var wikidataCheckedAt: Date? = nil
    var websiteHoursSource: PlaceSupplementalSource? = nil
    var websiteHoursCheckedAt: Date? = nil

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
                            source: result.placeProvider.detailsSource,
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
                     source: identity.provider.detailsSource,
                     fetchedAt: Date())
    }

    func merging(_ newer: PlaceDetails) -> PlaceDetails {
        return PlaceDetails(id: newer.id,
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
                     cacheGroupFetchedAt: newer.cacheGroupFetchedAt ?? cacheGroupFetchedAt,
                     openingHoursURL: newer.openingHoursURL ?? openingHoursURL,
                     supplementalSource: newer.supplementalSource ?? supplementalSource,
                     wikidataCheckedAt: newer.wikidataCheckedAt ?? wikidataCheckedAt,
                     websiteHoursSource: newer.websiteHoursSource ?? websiteHoursSource,
                     websiteHoursCheckedAt: newer.websiteHoursCheckedAt ?? websiteHoursCheckedAt)
    }

    nonisolated var needsCacheRefresh: Bool {
        if officialHoursWeekExpired { return true }
        if websiteHoursSource != nil,
           Date().timeIntervalSince(websiteHoursCheckedAt ?? .distantPast) >= 6 * 3_600 { return true }
        if supplementalSource?.fields.contains("godziny") == true,
           Date().timeIntervalSince(wikidataCheckedAt ?? .distantPast) >= 3_600 { return true }
        let groups = cacheGroupFetchedAt ?? Self.legacyCacheGroups(for: self)
        let ttl: [String: TimeInterval] = [
            "identity": 30 * 24 * 60 * 60,
            "contact": 7 * 24 * 60 * 60,
            "hours": openingHours == nil ? 60 * 60 : 12 * 60 * 60,
            "access": 3 * 24 * 60 * 60
        ]
        let now = Date()
        for (group, lifetime) in ttl {
            guard let fetchedAt = groups[group] else { return true }
            if now.timeIntervalSince(fetchedAt) >= lifetime { return true }
        }
        return false
    }

    nonisolated var officialHoursWeekExpired: Bool {
        guard let source = websiteHoursSource,
              source.title == "Biedronka · godziny orientacyjne" else { return false }
        return OfficialStoreHoursParser.weekKey(at: source.fetchedAt) != OfficialStoreHoursParser.weekKey(at: Date())
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
    case openStreetMap, mapKit, openFreeMap, inPost

    var title: String {
        switch self {
        case .openStreetMap: "OpenStreetMap"
        case .mapKit: "Apple Maps"
        case .openFreeMap: "OpenFreeMap / OpenStreetMap"
        case .inPost: "InPost"
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
    private let logger = Logger(subsystem: "NaviAstra", category: "PlaceDetails")
    private var endpoint: URL {
        if let configured = UserDefaults.standard.string(forKey: "overpassServer"),
           let url = URL(string: configured),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return url
        }
        return URL(string: "https://overpass-api.de/api/interpreter")!
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
        let pickupDetails = objects.compactMap { object -> PlaceDetails? in
            guard ParcelPOI.category(tags: object.tags) == "parcel_pickup",
                  let id = OpenStreetMapObjectID(object.id) else { return nil }
            return makeDetails(id: id.cacheKey, fallbackName: object.name, tags: object.tags,
                               includePickupServices: true)
        }
        await PlaceDetailsCache.shared.store(pickupDetails, keySuffix: "/parcel-pickup")
    }

    func cachedDetails(for identity: PlaceIdentity) async -> PlaceDetails? {
        await PlaceDetailsCache.shared.value(for: identity.cacheKey, allowExpired: true)
    }

    func supplementalDetails(_ details: PlaceDetails, for identity: PlaceIdentity,
                             forceRefresh: Bool = false, hoursOnly: Bool = false) async -> PlaceDetails {
        let suffix = identity.category == "parcel_pickup" ? "/parcel-pickup" : ""
        let resolvedKey = details.id.hasSuffix(suffix) ? details.id : details.id + suffix
        let keys = Array(Set([identity.cacheKey, resolvedKey]))
        let revisions = await PlaceDetailsCache.shared.revisions(for: keys)
        var base = details
        if base.officialHoursWeekExpired {
            base.openingHours = nil; base.websiteHoursCheckedAt = nil; base.websiteHoursSource = nil
        }
        var enriched = await OfficialStoreHoursProvider.enrich(base, for: identity, forceRefresh: forceRefresh)
        enriched = await WebsiteOpeningHoursProvider.enrich(enriched, for: identity, forceRefresh: forceRefresh)
        if !hoursOnly || enriched.openingHours == nil {
            enriched = await WikidataPlaceDetailsProvider.enrich(enriched, for: identity, forceRefresh: forceRefresh)
        }
        if details.website == nil, enriched.website != nil, enriched.openingHours == nil {
            enriched = await WebsiteOpeningHoursProvider.enrich(enriched, for: identity, forceRefresh: forceRefresh)
        }
        guard !Task.isCancelled else { return details }
        await PlaceDetailsCache.shared.storeSupplement(enriched, for: keys, expectedRevisions: revisions,
                                                       originalFetchedAt: details.fetchedAt)
        return enriched
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
        } else if let cached = await PlaceDetailsCache.shared.value(for: identity.cacheKey, allowExpired: true),
                  cached.id.hasPrefix("osm/") {
            let components = cached.id.split(separator: "/")
            requestedID = components.count == 3
                ? OpenStreetMapObjectID("\(components[1]):\(components[2])") : nil
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
            selector = "nwr(around:150,\(identity.coordinate.latitude),\(identity.coordinate.longitude))[~\"^(name(:.*)?|official_name|short_name|alt_name|brand|operator)$\"~\".\"];"
        }
        let query = "[out:json][timeout:6];\(selector)out center tags;"
        // The shared transport owns failover. A valid empty/ambiguous reply is
        // definitive; querying mirrors repeats the same data and can amplify 429s.
        let requestEndpoint = endpoint
        try Task.checkCancellation()
        do {
            let reply = try await fetchReply(query: query, from: requestEndpoint,
                                             timeout: 8)
            guard reply.remark == nil else { throw PlaceDetailsError.unavailable }

            let element: Element?
            if let requestedID {
                element = reply.elements.first(where: { $0.type == requestedID.type && $0.id == requestedID.value })
            } else {
                element = Self.bestMatch(in: reply.elements, for: identity)
            }
            guard let element,
                  let resolvedID = OpenStreetMapObjectID("\(element.type):\(element.id)") else {
                logger.notice("No confident OSM match provider=\(identity.provider.rawValue, privacy: .public) candidates=\(reply.elements.count)")
                if requestedID != nil { return nil }
                throw PlaceDetailsError.notMatched
            }
            let tags = element.tags ?? [:]
            logger.info("Resolved OSM type=\(element.type, privacy: .public) id=\(element.id) hasHours=\(tags["opening_hours"] != nil)")
            let resolvedKey = resolvedID.cacheKey
            let isPickupService = identity.category == "parcel_pickup"
            let downloaded = Self.makeDetails(id: resolvedKey, fallbackName: partial.name, tags: tags,
                                              includePickupServices: isPickupService)
            let resolvedCacheKey = resolvedKey + (isPickupService ? "/parcel-pickup" : "")
            await PlaceDetailsCache.shared.store(downloaded, for: Array(Set([resolvedCacheKey, requestKey])))
            return partial.merging(downloaded)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlaceDetailsError {
            throw error
        } catch {
            logger.error("Details host=\(requestEndpoint.host ?? "unknown", privacy: .public) failure=\(String(describing: error), privacy: .public)")
            throw PlaceDetailsError.unavailable
        }
    }

    static func bestMatch(in elements: [Element], for identity: PlaceIdentity) -> Element? {
        let candidates = elements.compactMap { candidate -> (element: Element, score: Double)? in
            guard let tags = candidate.tags,
                  let coordinate = candidate.coordinate else { return nil }
            let distance = coordinate.distance(to: identity.coordinate)
            if identity.provider == .openFreeMap, let externalID = identity.externalID,
               let tileID = Int64(externalID), tileID != Int64.min,
               candidate.id == tileID || candidate.id == abs(tileID) {
                let categoryMatch = identity.category.map { Self.matchesCategory($0, tags: tags) } ?? false
                guard !Self.hasConflictingAddress(identity.address, tags: tags),
                      Self.matchesExactName(Self.normalized(identity.name), tags: tags),
                      distance <= 150 else { return nil }
                let categoryScore = categoryMatch ? 180.0 : 0
                return (candidate, 1_500 + categoryScore - distance)
            }

            guard distance <= 150,
                  !Self.hasConflictingAddress(identity.address, tags: tags),
                  let nameScore = Self.nameMatchScore(identity, tags: tags),
                  nameScore >= 400 else { return nil }
            let categoryMatch = identity.category.map { Self.matchesCategory($0, tags: tags) } ?? false
            let addressMatch = Self.addressMatchScore(identity.address, tags: tags)
            guard distance <= 40 || (nameScore >= 760 && (categoryMatch || addressMatch >= 100)) else { return nil }
            let score = nameScore + (categoryMatch ? 180 : 0) + addressMatch - distance * 2
            return (candidate, score)
        }
        let ranked = candidates.sorted { $0.score > $1.score }
        if let best = ranked.first,
           ranked.count == 1 || best.score - ranked[1].score >= 150 {
            return best.element
        } else {
            return nil
        }
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

        let (data, response) = try await OSMRequestTransport.shared.data(for: request, priority: true, maximumDuration: 14)
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
        let taggedNames = [tags["name"], tags["official_name"], tags["short_name"], tags["alt_name"], tags["brand"], tags["operator"],
                           ParcelPOI.name(tags: tags, fallback: "")].compactMap { $0 }
            + tags.filter { $0.key.lowercased().hasPrefix("name:") }.map(\.value)
        for value in taggedNames.flatMap({ $0.split(separator: ";").map(String.init) }) {
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
        let appleAliases = ["foodmarket": ["supermarket", "convenience", "greengrocer", "deli"],
                            "gasstation": ["fuel"], "parkinggarage": ["parking"], "store": ["shop"]]
        for alias in aliases { aliases.append(contentsOf: appleAliases[alias] ?? []) }
        aliases = aliases.filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return false }
        return ParcelPOI.category(tags: tags).map { aliases.contains(normalized($0)) } == true ||
            tags.keys.contains(where: { aliases.contains(normalized($0)) }) ||
            tags.values.contains(where: { aliases.contains(normalized($0)) })
    }

    private static func nameMatchScore(_ identity: PlaceIdentity, tags: [String: String]) -> Double? {
        let taggedNames = ([tags["name"], tags["official_name"], tags["short_name"], tags["alt_name"], tags["brand"], tags["operator"],
                            ParcelPOI.name(tags: tags, fallback: ""), ParcelPOI.brand(tags: tags),
                            ParcelPOI.operatorName(tags: tags)].compactMap { $0 }
            + tags.filter { $0.key.lowercased().hasPrefix("name:") }.map(\.value)).flatMap { $0.split(separator: ";").map { normalized(String($0)) } }
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
        let actualStreet = [tags["addr:street"], tags["addr:housenumber"]].compactMap { $0 }.joined(separator: " ")
        if PlaceAddressMatching.hasStreetConflict(expected, actual: actualStreet) { return true }
        guard let expected, let expectedNumber = PhotonSearchProvider.houseNumber(in: expected),
              let actualNumber = tags["addr:housenumber"].map(PhotonSearchProvider.normalized) else { return false }
        return expectedNumber != actualNumber
    }

    private static func makeDetails(id: String, fallbackName: String, tags: [String: String],
                                    includePickupServices: Bool = false) -> PlaceDetails {
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
        let category = ParcelPOI.category(tags: tags, includePickupServices: includePickupServices) ?? ["amenity", "shop", "tourism", "leisure", "office", "craft", "historic"]
            .compactMap { tags[$0] }
            .first

        let name = ParcelPOI.name(tags: tags, fallback: fallbackName, includePickupServices: includePickupServices)
        let phone = tags["contact:phone"] ?? tags["phone"]
        let website = tags["contact:website"] ?? tags["website"]
        let imageURL = tags["image"]
        let imageAttribution = tags["image:attribution"]
        let imageLicense = tags["image:license"]
        let wikimediaCommons = tags["wikimedia_commons"]
        let wikidataID = tags["wikidata"]
        let brandIdentifiers = category == "parcel_pickup"
            ? [tags["post_office:brand:wikidata"]]
            : [tags["brand:wikidata"], tags["operator:wikidata"]]
        let brandWikidataID = brandIdentifiers
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
                            brand: ParcelPOI.brand(tags: tags, includePickupServices: includePickupServices),
                            operatorName: ParcelPOI.operatorName(tags: tags, includePickupServices: includePickupServices),
                            category: category,
                            address: address,
                            openingHours: ParcelPOI.openingHours(tags: tags, includePickupServices: includePickupServices)
                                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
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
                            cacheGroupFetchedAt: cacheGroupFetchedAt,
                            openingHoursURL: tags["opening_hours:url"])
    }

    private static func countryCode(from tags: [String: String]) -> String? {
        guard let value = tags["addr:country"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 2, value.allSatisfy(\.isLetter) else { return nil }
        return value.lowercased()
    }

    private struct Reply: Decodable { let elements: [Element]; let remark: String? }
    struct Element: Decodable {
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
    struct Center: Decodable { let lat: Double; let lon: Double }
}

enum PlaceDetailsError: LocalizedError {
    case unavailable
    case invalidResponse
    case notMatched

    var errorDescription: String? {
        switch self {
        case .unavailable: "Szczegóły miejsca z OpenStreetMap są chwilowo niedostępne."
        case .invalidResponse: "Usługa szczegółów miejsca zwróciła nieprawidłowe dane."
        case .notMatched: "Nie udało się jednoznacznie dopasować miejsca w OpenStreetMap. Zachowano dostępne informacje."
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
    static var failures: [String: (until: Date, error: PlaceDetailsError)] = [:]

    static func load(key: String, forceRefresh: Bool = false,
                     operation: @escaping @MainActor () async throws -> PlaceDetails?) async throws -> PlaceDetails? {
        if let pending = pending[key] { return try await pending.value }
        if forceRefresh {
            missingUntil[key] = nil
            failures[key] = nil
        } else if let failure = failures[key], failure.until > Date() {
            throw failure.error
        } else if let until = missingUntil[key], until > Date() {
            return nil
        }
        let task = Task { try await operation() }
        pending[key] = task
        defer { pending[key] = nil }
        let value: PlaceDetails?
        do { value = try await task.value }
        catch let error as PlaceDetailsError {
            failures = failures.filter { $0.value.until > Date() }
            if failures.count >= 200 { failures.removeAll() }
            let lifetime: TimeInterval = if case .notMatched = error { 300 } else { 30 }
            failures[key] = (Date().addingTimeInterval(lifetime), error)
            throw error
        }
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
    private var versions: [String: UInt64] = [:]

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

    func revisions(for ids: [String]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, versions[$0, default: 0]) })
    }

    func storeSupplement(_ details: PlaceDetails, for ids: [String], expectedRevisions: [String: UInt64],
                         originalFetchedAt: Date) {
        guard !Task.isCancelled, ids.allSatisfy({ id in
            versions[id, default: 0] == expectedRevisions[id] &&
                (entries[id].map { $0.fetchedAt <= originalFetchedAt } ?? true)
        }) else { return }
        store(details, for: ids)
    }

    func store(_ details: PlaceDetails, for ids: [String]) {
        for id in ids where entries[id].map({ $0.fetchedAt <= details.fetchedAt }) ?? true {
            entries[id] = details
            versions[id, default: 0] &+= 1
        }
        if entries.count > 1_000 {
            let newestEntries = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(1_000)
                .map { ($0.key, $0.value) }
            entries = Dictionary(uniqueKeysWithValues: newestEntries)
        }
        persist()
    }

    func store(_ details: [PlaceDetails], keySuffix: String = "") {
        guard !details.isEmpty else { return }
        for detail in details {
            let key = detail.id + keySuffix
            entries[key] = detail
            versions[key, default: 0] &+= 1
        }
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
        versions = versions.filter { entries[$0.key] != nil }
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

/// Compare street names only when both addresses explicitly identify their street
/// and building number. A shared number on neighbouring streets is not a match.
enum PlaceAddressMatching {
    static func hasStreetConflict(_ expected: String?, actual: String?) -> Bool {
        guard let expected, let actual,
              let left = street(in: expected), let right = street(in: actual) else { return false }
        return left != right
    }
    private static func street(in address: String) -> String? {
        guard let number = PhotonSearchProvider.houseNumber(in: address) else { return nil }
        for part in address.split(separator: ",").map(String.init) where PhotonSearchProvider.houseNumber(in: part) == number {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: number) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.matches(in: part, range: NSRange(part.startIndex..., in: part)).last,
                  let range = Range(match.range, in: part) else { continue }
            var street = String(part[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if street.isEmpty { street = String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            street = street.replacingOccurrences(of: #"^(?:ulica|ul\.?|aleja|al\.?|plac|pl\.?|osiedle|os\.?)\s+"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            let value = street.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
                .filter { $0.isLetter || $0.isNumber }
            if value.count >= 3 { return value }
        }
        return nil
    }
}
