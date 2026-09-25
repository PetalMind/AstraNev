import Foundation
import MapKit

enum SearchError: LocalizedError, Equatable {
    case unavailable, offline, timeout, rateLimited, locationRequired, noActiveRoute
    case locationNotFound(String)

    var canRetry: Bool {
        switch self {
        case .unavailable, .offline, .timeout, .rateLimited: true
        case .locationRequired, .noActiveRoute, .locationNotFound: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .locationRequired: "Włącz lokalizację, wybierz obszar mapy lub dopisz miejscowość."
        case .noActiveRoute: "Wyszukiwanie po trasie wymaga aktywnej nawigacji."
        case .locationNotFound(let name): "Nie znaleziono lokalizacji: \(name)."
        case .unavailable: "Wyszukiwanie miejsc jest chwilowo niedostępne."
        case .offline: "Brak połączenia z internetem."
        case .timeout: "Wyszukiwanie miejsc przekroczyło limit czasu."
        case .rateLimited: "Wyszukiwanie jest chwilowo ograniczone przez usługę."
        }
    }

    static func classify(_ error: Error) -> SearchError {
        if let searchError = error as? SearchError { return searchError }
        guard let urlError = error as? URLError else { return .unavailable }
        return switch urlError.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
            .offline
        default: .unavailable
        }
    }

    static func httpStatus(_ statusCode: Int) -> SearchError {
        switch statusCode {
        case 429: .rateLimited
        case 408, 504: .timeout
        default: .unavailable
        }
    }

    static func preferredFailure(from errors: [SearchError]) -> SearchError {
        for candidate in [SearchError.offline, .timeout, .rateLimited, .unavailable] where errors.contains(candidate) {
            return candidate
        }
        return errors.last ?? .unavailable
    }
}

struct SearchResult: Identifiable {
    var destination: Destination
    var street: String?
    var houseNumber: String?
    var city: String?
    var countryCode: String?

    var isPOI = false
    var osmID: String? = nil
    var providerID: String? = nil
    var placeProvider: PlaceProvider = .openStreetMap
    var category: String? = nil
    var brand: String? = nil
    var operatorName: String? = nil
    var openingHours: String? = nil
    var phone: String? = nil
    var website: String? = nil
    var timeZoneIdentifier: String? = nil
    var photonImportance: Double? = nil
    var straightDistance: Double? = nil
    var travelTime: Double? = nil
    var travelDistance: Double? = nil
    var detour: Double? = nil
    var detourDistance: Double? = nil
    var travelEstimateStatus: TravelEstimateStatus = .notRequested

    var id: UUID { destination.id }
    var placeIdentity: PlaceIdentity {
        let osmObject = placeProvider == .openStreetMap ? OpenStreetMapObjectID(osmID) : nil
        return PlaceIdentity(provider: placeProvider,
                             externalID: osmObject?.value.description ?? osmID,
                             providerID: providerID,
                             osmType: osmObject?.type,
                             coordinate: destination.coordinate,
                             name: destination.name,
                             category: category,
                             address: destination.address,
                             brand: brand,
                             operatorName: operatorName,
                             timeZoneIdentifier: timeZoneIdentifier)
    }

    func mergingMetadata(from other: SearchResult) -> SearchResult {
        var merged = self
        merged.isPOI = merged.isPOI || other.isPOI
        if merged.osmID == nil { merged.osmID = other.osmID }
        if merged.providerID == nil { merged.providerID = other.providerID }
        if merged.category == nil { merged.category = other.category }
        if merged.brand == nil { merged.brand = other.brand }
        if merged.operatorName == nil { merged.operatorName = other.operatorName }
        if merged.openingHours == nil { merged.openingHours = other.openingHours }
        if merged.phone == nil { merged.phone = other.phone }
        if merged.website == nil { merged.website = other.website }
        if merged.timeZoneIdentifier == nil { merged.timeZoneIdentifier = other.timeZoneIdentifier }
        if merged.photonImportance == nil { merged.photonImportance = other.photonImportance }
        return merged.replacingAddressFields(from: other)
    }

    private func replacingAddressFields(from other: SearchResult) -> SearchResult {
        var merged = self
        if merged.street == nil { merged.street = other.street }
        if merged.houseNumber == nil { merged.houseNumber = other.houseNumber }
        if merged.city == nil { merged.city = other.city }
        if merged.countryCode == nil { merged.countryCode = other.countryCode }
        if merged.destination.address == nil, let address = other.destination.address {
            merged.destination = Destination(name: merged.destination.name,
                                             coordinate: merged.destination.coordinate,
                                             address: address)
        }
        return merged
    }

    var travelSummary: String? {
        if let detour {
            let minutes = max(0, Int((detour / 60).rounded(.up)))
            if let detourDistance {
                return "\(String(format: "%.1f", detourDistance / 1_000)) km od trasy • +\(minutes) min"
            }
            return "+\(minutes) min objazdu (szacunek)"
        }
        if let travelTime, let travelDistance {
            return "\(String(format: "%.1f", travelDistance / 1000)) km · ~\(max(1, Int((travelTime / 60).rounded(.up)))) min"
        }
        if travelEstimateStatus == .calculating {
            if let distance = detourDistance {
                return "\(String(format: "%.1f", distance / 1_000)) km od trasy • obliczanie czasu…"
            }
            if let straightDistance {
                return "\(String(format: "%.1f", straightDistance / 1_000)) km w linii prostej • obliczanie czasu…"
            }
            return "Obliczanie czasu…"
        }
        if travelEstimateStatus == .unavailable {
            if let distance = detourDistance {
                return "\(String(format: "%.1f", distance / 1_000)) km od trasy • objazd niedostępny"
            }
            if let straightDistance {
                return "\(String(format: "%.1f", straightDistance / 1_000)) km w linii prostej • czas niedostępny"
            }
            return "Czas dojazdu niedostępny"
        }
        if let straightDistance {
            return "\(String(format: "%.1f", straightDistance / 1000)) km w linii prostej • ETA niedostępne"
        }
        return nil
    }
    var isAddress: Bool {
        !isPOI && ((houseNumber != nil && (street != nil || city != nil)) || street != nil)
    }
    var subtitle: String {
        if let address = destination.address { return address }
        if isAddress { return houseNumber == nil ? "Ulica lub obszar adresowy" : "Adres · punkt budynku" }
        return isPOI ? "Miejsce · \(placeProvider == .mapKit ? "Apple Maps" : "OpenStreetMap")" : "Miejsce lub obszar"
    }
}

enum TravelEstimateStatus: Equatable {
    case notRequested
    case calculating
    case unavailable
}

protocol SearchProvider {
    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult]
}

/// Publishes every completed source without waiting for the slowest service.
@MainActor
struct SearchProviderBatch {
    struct Request {
        var authoritative = false
        var operation: @MainActor @Sendable () async throws -> [SearchResult]
    }
    private struct Reply {
        var index: Int
        var results: [SearchResult]?
        var error: SearchError?
    }

    static func search(_ requests: [Request],
                       onUpdate: ([SearchResult]) -> Void) async throws -> [SearchResult] {
        try await withThrowingTaskGroup(of: Reply.self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { @MainActor in
                    do {
                        try Task.checkCancellation()
                        let results = try await request.operation()
                        try Task.checkCancellation()
                        return Reply(index: index, results: results)
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        return Reply(index: index, error: SearchError.classify(error))
                    }
                }
            }
            var replies: [Int: Reply] = [:]
            var merged: [SearchResult] = []
            for try await reply in group {
                try Task.checkCancellation()
                replies[reply.index] = reply
                // Stable source precedence keeps identity and metadata from jumping as replies arrive.
                let ordered = replies.values.sorted { $0.index < $1.index }
                if let exact = ordered.first(where: {
                    requests[$0.index].authoritative && !($0.results ?? []).isEmpty
                }) {
                    merged = exact.results ?? []
                    onUpdate(merged)
                    group.cancelAll()
                    return merged
                }
                if let results = reply.results, !results.isEmpty {
                    merged = ordered.flatMap { $0.results ?? [] }
                    onUpdate(merged)
                }
            }
            if replies.values.contains(where: { $0.results != nil }) { return merged }
            throw SearchError.preferredFailure(from: replies.values.compactMap { $0.error })
        }
    }
}

struct AddressSearchProvider: SearchProvider {
    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        try await search(query, near: near, onUpdate: { _ in })
    }

    func search(_ query: String, near: Coordinate?, includeUUGFallback: Bool = false,
                onUpdate: ([SearchResult]) -> Void) async throws -> [SearchResult] {
        var requests: [SearchProviderBatch.Request] = [
            .init { try await PhotonSearchProvider().search(query, near: near) },
            .init { try await MapKitSearchProvider().search(query, near: near) }
        ]
        if includeUUGFallback, PhotonSearchProvider.houseNumber(in: query) != nil {
            requests.append(.init(authoritative: true) {
                if let exact = await GUGiKAddressProvider().searchExact(query) { return [exact] }
                // GUGiK is optional: a miss must not turn failures of other services into success.
                throw SearchError.unavailable
            })
        } else if includeUUGFallback {
            requests.append(.init {
                let results = await GUGiKAddressProvider().search(query)
                guard !results.isEmpty else { throw SearchError.unavailable }
                return results
            })
        }
        return try await SearchProviderBatch.search(requests, onUpdate: onUpdate)
    }
}

struct MapKitSearchProvider: SearchProvider {
    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let near {
            request.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        }
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await search.start()
        } onCancel: {
            // Typing another query or selecting a partial result stops the old Apple request too.
            Task { @MainActor in search.cancel() }
        }
        try Task.checkCancellation()
        let requestedNumber = PhotonSearchProvider.houseNumber(in: query)
        return Array(response.mapItems.compactMap { item -> SearchResult? in
            let address = item.address
            let addressRepresentations = item.addressRepresentations
            let isPOI = item.pointOfInterestCategory != nil
            let addressNames = [
                address?.shortAddress,
                addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
                address?.fullAddress
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            let name = isPOI ? item.name ?? addressNames : addressNames ?? item.name
            guard let name else { return nil }

            let addressText = [address?.fullAddress, address?.shortAddress, name]
                .compactMap { $0 }
                .joined(separator: " ")
            if let requestedNumber,
               !Self.containsExactHouseNumber(requestedNumber, in: addressText) { return nil }

            let location = item.location
            let coordinate = Coordinate(latitude: location.coordinate.latitude,
                                        longitude: location.coordinate.longitude)
            guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
            let category = item.pointOfInterestCategory?.rawValue
            return SearchResult(destination: Destination(name: name, coordinate: coordinate,
                                                         address: isPOI ? address?.fullAddress : nil), street: nil,
                                houseNumber: requestedNumber, city: addressRepresentations?.cityName,
                                countryCode: addressRepresentations?.region?.identifier.lowercased(),
                                isPOI: isPOI, providerID: item.identifier?.rawValue,
                                placeProvider: .mapKit, category: category,
                                phone: item.phoneNumber,
                                website: item.url?.absoluteString,
                                timeZoneIdentifier: item.timeZone?.identifier)
        })
    }

    private static func containsExactHouseNumber(_ requestedNumber: String, in address: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}])\d+[a-zA-Z]?(?:/\d+)?(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(address.startIndex..<address.endIndex, in: address)
        return regex.matches(in: address, range: range).contains { match in
            guard let matchRange = Range(match.range, in: address) else { return false }
            return PhotonSearchProvider.normalized(String(address[matchRange])) == requestedNumber
        }
    }
}

struct PhotonSearchProvider: SearchProvider {
    var endpoint = URL(string: UserDefaults.standard.string(forKey: "photonServer") ?? "https://photon.komoot.io/api/")!

    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        try await search(query, near: near, addressesOnly: true)
    }
    func search(_ query: String, near: Coordinate?, addressesOnly: Bool,
                osmTag: String? = nil) async throws -> [SearchResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "lang", value: "pl"),
                     // Keep separate branches sharing a name/postcode. Dedupe by identity downstream.
                     URLQueryItem(name: "dedupe", value: "0")]
        if let osmTag { items.append(URLQueryItem(name: "osm_tag", value: osmTag)) }
        if let near {
            items += [URLQueryItem(name: "lat", value: String(near.latitude)), URLQueryItem(name: "lon", value: String(near.longitude)),
                      URLQueryItem(name: "location_bias_scale", value: "0.1")]
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.unavailable }
        guard (200...299).contains(http.statusCode) else { throw SearchError.httpStatus(http.statusCode) }
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        let requestedNumber = addressesOnly ? Self.houseNumber(in: query) : nil
        let found = collection.features.compactMap { feature -> SearchResult? in
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            let p = feature.properties
            let streetLine = [p.street, p.housenumber].compactMap { $0 }.joined(separator: " ")
            let locality = [p.postcode, p.city ?? p.locality].compactMap { $0 }.joined(separator: " ")
            let name = [streetLine.isEmpty ? p.name : streetLine, locality.isEmpty ? nil : locality].compactMap { $0 }.joined(separator: ", ")
            guard !name.isEmpty else { return nil }
            // Never silently resolve a numbered address to the centre of a city or street.
            if let requestedNumber, Self.normalized(p.housenumber) != requestedNumber { return nil }
            let coordinate = Coordinate(latitude: feature.geometry.coordinates[1], longitude: feature.geometry.coordinates[0])
            guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
            let poi = !addressesOnly && p.osm_key.map {
                ["amenity", "shop", "tourism", "leisure", "office", "healthcare", "craft", "historic", "sport", "railway", "public_transport", "natural", "cuisine"].contains($0)
            } == true
            let title = !addressesOnly ? (p.name ?? name) : name
            return SearchResult(destination: Destination(name: title, coordinate: coordinate, address: !addressesOnly && name != title ? name : nil), street: p.street,
                                houseNumber: p.housenumber, city: p.city ?? p.locality, countryCode: p.countrycode,
                                isPOI: poi, osmID: p.osm_id.map { "\(p.osm_type ?? ""):\($0)" },
                                category: p.osm_value, photonImportance: p.importance)
        }
        let sorted = found.sorted { a, b in
            let aExact = requestedNumber.map { Self.normalized(a.houseNumber) == $0 } ?? false
            let bExact = requestedNumber.map { Self.normalized(b.houseNumber) == $0 } ?? false
            if aExact != bExact { return aExact }
            guard let near else { return false }
            return near.distance(to: a.destination.coordinate) < near.distance(to: b.destination.coordinate)
        }
        return sorted
    }
    nonisolated static func normalized(_ value: String?) -> String {
        (value ?? "").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "/" }
    }
    static func houseNumber(in query: String) -> String? {
        let pattern = #"(?<![\p{L}\p{N}])\d+[a-zA-Z]?(?:/\d+)?(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let queryWithoutPostcodes = query.replacingOccurrences(of: #"\b\d{2}-\d{3}\b"#, with: "", options: .regularExpression)
        let matches = regex.matches(in: queryWithoutPostcodes, range: NSRange(queryWithoutPostcodes.startIndex..<queryWithoutPostcodes.endIndex, in: queryWithoutPostcodes))
        guard let match = matches.last, let range = Range(match.range, in: queryWithoutPostcodes) else { return nil }
        return normalized(String(queryWithoutPostcodes[range]))
    }
    private struct Collection: Decodable { let features: [Feature] }
    private struct Feature: Decodable { let geometry: Geometry; let properties: Properties }
    private struct Geometry: Decodable { let coordinates: [Double] }
    private struct Properties: Decodable {
        let name: String?
        let street: String?
        let housenumber: String?
        let postcode: String?
        let city: String?
        let locality: String?
        let countrycode: String?
        let osm_id: Int64?
        let osm_type: String?
        let osm_key: String?
        let osm_value: String?
        let importance: Double?
    }
}

struct GUGiKAddressProvider {
    func search(_ query: String) async -> [SearchResult] {
        guard let reply = await request(address: query, exactNumber: false),
              let addresses = reply.results?.values else { return [] }

        return addresses.compactMap { address -> (SearchResult, Double)? in
            guard let result = searchResult(for: address) else { return nil }
            return (result, Double(address.distance ?? "") ?? .infinity)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.destination.name.localizedStandardCompare(rhs.0.destination.name) == .orderedAscending
        }
        .map { $0.0 }
    }

    func searchExact(_ query: String) async -> SearchResult? {
        guard let requestedNumber = PhotonSearchProvider.houseNumber(in: query),
              let reply = await request(address: query, exactNumber: true) else { return nil }
        let normalizedQuery = normalized(query)
        let matches = reply.results?.values.filter { candidate in
            guard normalized(candidate.number) == requestedNumber,
                  let city = candidate.city else { return false }
            let cityKey = normalized(city)
            guard !cityKey.isEmpty else { return false }
            let cityMatches = normalizedQuery.contains(cityKey)
            let street = normalizedStreet(candidate.street)
            let streetMatches = street.isEmpty || normalizedStreet(query).contains(street)
            return cityMatches && streetMatches
        } ?? []
        // Duplicate locality/street names must never select an arbitrary UUG record.
        guard matches.count == 1, let address = matches.first else { return nil }
        return searchResult(for: address)
    }

    func preciseDestination(for result: SearchResult) async -> Destination? {
        guard result.providerID?.hasPrefix("gugik:") != true,
              result.isAddress, result.countryCode?.lowercased() == "pl",
              let city = result.city, let street = result.street, let number = result.houseNumber else { return nil }
        guard let reply = await request(address: "\(city), \(street) \(number)", exactNumber: true) else { return nil }
        let expectedStreet = normalizedStreet(street)
        let matches = reply.results?.values.filter {
            let returnedStreet = normalizedStreet($0.street)
            return normalized($0.number) == normalized(number)
                && normalized($0.city) == normalized(city)
                && !returnedStreet.isEmpty
                && (returnedStreet == expectedStreet
                    || returnedStreet.contains(expectedStreet) || expectedStreet.contains(returnedStreet))
        } ?? []
        guard matches.count == 1, let address = matches.first,
              let coordinate = coordinate(for: address) else { return nil }
        return Destination(name: result.destination.name, coordinate: coordinate)
    }

    func reverseGeocode(_ coordinate: Coordinate) async -> String? {
        guard isWithinPolandEnvelope(coordinate) else { return nil }
        var components = URLComponents(string: "https://services.gugik.gov.pl/uug/")!
        components.queryItems = [
            URLQueryItem(name: "request", value: "GetAddressReverse"),
            URLQueryItem(name: "location", value: "POINT(\(coordinate.longitude) \(coordinate.latitude))"),
            URLQueryItem(name: "srid", value: "4326")
        ]
        guard let reply = await request(components),
              let nearest = reply.results?.values.compactMap({ address -> (String, Double?)? in
                  guard let formatted = formattedAddress(for: address) else { return nil }
                  return (formatted, Double(address.distance ?? ""))
              }).min(by: { ($0.1 ?? .infinity) < ($1.1 ?? .infinity) }) else { return nil }

        if let distance = nearest.1, distance.isFinite, distance >= 0 {
            let meters = Int(min(distance.rounded(), 100_000))
            return "Najbliższy adres: \(nearest.0) (\(meters) m od punktu)"
        }
        return "Adres w pobliżu: \(nearest.0)"
    }

    private func request(address: String, exactNumber: Bool) async -> Reply? {
        var components = URLComponents(string: "https://services.gugik.gov.pl/uug/")!
        components.queryItems = [URLQueryItem(name: "request", value: "GetAddress"),
                                 URLQueryItem(name: "address", value: address),
                                 URLQueryItem(name: "srid", value: "4326")]
        if exactNumber {
            components.queryItems?.append(URLQueryItem(name: "exact_number", value: "1"))
        }
        return await request(components)
    }

    private func request(_ components: URLComponents) async -> Reply? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: data)
    }

    private func searchResult(for address: Address) -> SearchResult? {
        guard let coordinate = coordinate(for: address),
              let name = formattedAddress(for: address) else { return nil }
        let identity = [address.idiip, address.teryt, address.simc, address.ulic, address.number]
            .compactMap { $0 }.joined(separator: ":")
        return SearchResult(destination: Destination(name: name, coordinate: coordinate),
                            street: address.street, houseNumber: address.number,
                            city: address.city, countryCode: "pl",
                            providerID: "gugik:\(identity.isEmpty ? name : identity)")
    }

    private func formattedAddress(for address: Address) -> String? {
        let streetLine = [address.street, address.number]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [address.code, address.city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let formatted = [streetLine, locality].filter { !$0.isEmpty }.joined(separator: ", ")
        return formatted.isEmpty ? nil : formatted
    }

    private func coordinate(for address: Address) -> Coordinate? {
        guard let longitude = Double(address.x ?? ""), let latitude = Double(address.y ?? ""),
              (48...56).contains(latitude), (13...25).contains(longitude) else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
    private func normalized(_ value: String?) -> String {
        (value ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber || $0 == "/" }
    }
    private func normalizedStreet(_ value: String?) -> String {
        var result = normalized(value)
        for prefix in ["ulica", "ul"] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
            break
        }
        return result
    }
    private func isWithinPolandEnvelope(_ coordinate: Coordinate) -> Bool {
        (48...56).contains(coordinate.latitude) && (13...25).contains(coordinate.longitude)
    }
    private struct Reply: Decodable { let results: [String: Address]? }
    private struct Address: Decodable {
        let city: String?
        let street: String?
        let number: String?
        let code: String?
        let x: String?
        let y: String?
        let teryt: String?
        let simc: String?
        let ulic: String?
        let idiip: String?
        let distance: String?
    }
}
