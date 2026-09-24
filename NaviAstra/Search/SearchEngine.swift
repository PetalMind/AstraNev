import Foundation

enum SearchIntent { case address, brand, category, place, coordinates, unknown }

struct ClassifiedQuery {
    var intent: SearchIntent
    var text: String
    var location: String? = nil
    var filter: String? = nil
    var photonTag: String? = nil
    var coordinate: Coordinate? = nil
    var alongRoute = false
}

struct QueryClassifier {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func classify(_ raw: String) -> ClassifiedQuery {
        let text = Self.normalize(raw)
        let parts = text.split { $0 == "," || $0 == ";" || $0.isWhitespace }.compactMap { Double($0) }
        if parts.count == 2, text.range(of: #"^[\d\s.,;+\-]+$"#, options: .regularExpression) != nil,
           (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) {
            return ClassifiedQuery(intent: .coordinates, text: raw, coordinate: Coordinate(latitude: parts[0], longitude: parts[1]))
        }
        let along = text.hasSuffix(" po trasie")
        let clean = along ? String(text.dropLast(" po trasie".count)) : text
        let brands = ["mcdonald's", "mcdonalds", "biedronka", "lidl", "orlen", "shell", "bp", "auchan", "aldi", "kaufland", "zabka", "rossmann", "ikea", "kfc", "doz"]
        for brand in brands where clean == brand || clean.hasPrefix(brand + " ") || clean.hasPrefix(brand + ",") {
            let suffix = String(clean.dropFirst(brand.count))
            let location = locationSuffix(suffix)
            let canonical = brand == "mcdonalds" ? "McDonald's" : brand == "zabka" ? "Żabka" : brand
            let pattern = NSRegularExpression.escapedPattern(for: canonical)
            return ClassifiedQuery(intent: .brand, text: canonical, location: location.isEmpty ? nil : location,
                                   filter: "[~\"^(brand|name)$\"~\"^\(pattern)($|[ ;])\",i]",
                                   photonTag: "brand:\(canonical)", alongRoute: along)
        }
        let categories: [(String, String)] = [
            ("stacja paliw", "amenity=fuel"), ("stacje paliw", "amenity=fuel"), ("paliwo", "amenity=fuel"),
            ("apteka", "amenity=pharmacy"), ("parking", "amenity=parking"), ("parkingi", "amenity=parking"),
            ("ladowarka", "amenity=charging_station"), ("supermarket", "shop=supermarket"),
            ("restauracja", "amenity=restaurant"), ("pizza", "cuisine=pizza"),
            ("kawa", "amenity=cafe"), ("hotel", "tourism=hotel"),
            ("szpital", "amenity=hospital"), ("bankomat", "amenity=atm")]
        for (word, tag) in categories where clean == word || clean.hasPrefix(word + " ") || clean.hasPrefix(word + ",") {
            let location = locationSuffix(String(clean.dropFirst(word.count)))
            let photonTag = tag.replacingOccurrences(of: "=", with: ":")
            return ClassifiedQuery(intent: .category, text: word, location: location.isEmpty ? nil : location,
                                   filter: "[\(tag)]", photonTag: photonTag, alongRoute: along)
        }
        let address = PhotonSearchProvider.houseNumber(in: clean) != nil || clean.hasPrefix("ul.") || clean.hasPrefix("ulica ")
        return ClassifiedQuery(intent: clean.isEmpty ? .unknown : address ? .address : .place, text: clean, alongRoute: along)
    }

    private func locationSuffix(_ suffix: String) -> String {
        var value = suffix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        if ["w tym obszarze", "w poblizu", "blisko mnie", "w okolicy", "near me"].contains(value) {
            return ""
        }
        for prefix in ["w ", "we ", "przy ", "obok "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SearchContext {
    var origin: Coordinate?
    var area: Coordinate? = nil
    var route: [Coordinate] = []
    var routeTarget: Coordinate? = nil
    var mode: TransportMode = .car
    var preferences = RoutingPreferences()
    var localDestinations: [Destination] = []
}

struct SearchEngine {
    var photon = PhotonSearchProvider()
    var poi = POISearchProvider()
    var matrix: ValhallaRouteProvider

    func search(_ query: String, context: SearchContext,
                onUpdate: ([SearchResult]) -> Void = { _ in }) async throws -> [SearchResult] {
        let intent = QueryClassifier().classify(query)
        if let coordinate = intent.coordinate {
            return [SearchResult(destination: Destination(name: query, coordinate: coordinate), street: nil, houseNumber: nil, city: nil, countryCode: nil)]
        }
        if intent.alongRoute && context.route.count < 2 { throw SearchError.noActiveRoute }
        var center = context.area ?? context.origin
        if let location = intent.location {
            center = try await resolve(location, near: center)
        }
        let searchCenter = center
        let needsEstimates = (intent.intent != .address || intent.alongRoute)
            && context.origin != nil && context.mode != .transit && context.mode != .parkRide
        func ranked(_ candidates: [SearchResult]) -> [SearchResult] {
            var unique: [SearchResult] = []
            for result in candidates {
                if intent.intent == .brand {
                    let name = QueryClassifier.normalize(result.destination.name)
                    let brand = QueryClassifier.normalize(result.brand ?? "")
                    let query = QueryClassifier.normalize(intent.text)
                    guard name.contains(query) || brand.contains(query) else { continue }
                }
                if intent.alongRoute {
                    guard MapMatcher.project(result.destination.coordinate, onto: context.route)
                        .map({ $0.distanceFromRoute <= 1500 }) == true else { continue }
                }
                if unique.contains(where: { existing in
                    (result.placeIdentity.provider == .openStreetMap
                     && existing.placeIdentity.provider == .openStreetMap
                     && result.placeIdentity.cacheKey == existing.placeIdentity.cacheKey) ||
                    (QueryClassifier.normalize(existing.destination.name) == QueryClassifier.normalize(result.destination.name)
                     && existing.destination.coordinate.distance(to: result.destination.coordinate) < 30)
                }) { continue }
                var value = result
                value.straightDistance = searchCenter.map { $0.distance(to: result.destination.coordinate) }
                value.travelEstimateStatus = needsEstimates ? .calculating : .notRequested
                unique.append(value)
            }
            return unique.sorted { ($0.straightDistance ?? .infinity) < ($1.straightDistance ?? .infinity) }
        }
        func publish(_ candidates: [SearchResult]) {
            let results = Array(ranked(candidates).prefix(8))
            if !results.isEmpty { onUpdate(results) }
        }
        let candidates: [SearchResult]
        if intent.intent == .address {
            candidates = try await AddressSearchProvider().search(intent.text, near: searchCenter, onUpdate: publish)
        } else {
            let photonTag = intent.intent == .category ? intent.photonTag : nil
            var requests: [SearchProviderBatch.Request] = []
            if intent.intent == .brand || intent.intent == .category {
                guard let searchCenter else { throw SearchError.locationRequired }
                // Keep local OSM coverage, but never block faster sources on Overpass.
                requests.append(.init {
                    try await poi.search(intent, near: searchCenter, route: intent.alongRoute ? context.route : [])
                })
            }
            requests.append(.init {
                try await photon.search(intent.text, near: searchCenter, addressesOnly: false, osmTag: photonTag)
            })
            requests.append(.init {
                try await MapKitSearchProvider().search(intent.text, near: searchCenter)
            })
            candidates = try await SearchProviderBatch.search(requests, onUpdate: publish)
        }
        try Task.checkCancellation()
        // Ordinary searches only need estimates for the eight visible places.
        // Along-route searches retain a wider candidate set to compare detours.
        var results = Array(ranked(candidates).prefix(intent.alongRoute ? 20 : 8))
        if !needsEstimates { return Array(results.prefix(8)) }
        if let origin = context.origin, !results.isEmpty, context.mode != .transit, context.mode != .parkRide {
            do {
                let targets = results.map { $0.destination.coordinate }
                let rows = try await matrix.searchMatrix(sources: [origin], targets: targets, mode: context.mode, preferences: context.preferences)
                for index in results.indices {
                    results[index].travelTime = rows[0][index].time
                    results[index].travelDistance = rows[0][index].distance.map { $0 * 1000 }
                    results[index].travelEstimateStatus = results[index].travelTime == nil ? .unavailable : .notRequested
                }
                if intent.alongRoute, let target = context.routeTarget {
                    // Compare the same routing model on both sides; never subtract a stale live ETA.
                    let onward = try await matrix.searchMatrix(sources: [origin] + targets, targets: [target], mode: context.mode, preferences: context.preferences)
                    if let baseline = onward[0][0].time {
                        for index in results.indices {
                            if let first = results[index].travelTime, let second = onward[index + 1][0].time {
                                results[index].detour = max(0, first + second - baseline)
                            }
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                for index in results.indices where results[index].travelEstimateStatus == .calculating {
                    results[index].travelEstimateStatus = .unavailable
                }
            }
        }
        try Task.checkCancellation()
        results.sort { a, b in
            // Ordinary searches are nearest-first even when routing fails for a close POI.
            // Only an explicit along-route search ranks by added journey time.
            if !intent.alongRoute, a.straightDistance != b.straightDistance {
                return (a.straightDistance ?? .infinity) < (b.straightDistance ?? .infinity)
            }
            let aTime = intent.alongRoute ? a.detour : a.travelTime
            let bTime = intent.alongRoute ? b.detour : b.travelTime
            if aTime != bTime { return (aTime ?? .infinity) < (bTime ?? .infinity) }
            let aLocal = context.localDestinations.contains { $0.coordinate.distance(to: a.destination.coordinate) < 20 }
            let bLocal = context.localDestinations.contains { $0.coordinate.distance(to: b.destination.coordinate) < 20 }
            if aLocal != bLocal { return aLocal }
            return (a.straightDistance ?? .infinity) < (b.straightDistance ?? .infinity)
        }
        return Array(results.prefix(8))
    }

    private func resolve(_ location: String, near center: Coordinate?) async throws -> Coordinate {
        let requests: [SearchProviderBatch.Request] = [
            .init(authoritative: true) {
                try await photon.search(location, near: center, addressesOnly: false)
            },
            .init(authoritative: true) {
                try await MapKitSearchProvider().search(location, near: center)
            }
        ]
        let results = try await SearchProviderBatch.search(requests, onUpdate: { _ in })
        guard let coordinate = results.first?.destination.coordinate else {
            throw SearchError.locationNotFound(location)
        }
        return coordinate
    }
}

struct POISearchProvider {
    var endpoint = URL(string: UserDefaults.standard.string(forKey: "overpassServer") ?? "https://overpass-api.de/api/interpreter")!

    func search(_ intent: ClassifiedQuery, near center: Coordinate, route: [Coordinate]) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        let radii: [Int]
        if !route.isEmpty {
            radii = [1500]
        } else if intent.intent == .brand {
            radii = [5000, 15000, 50000]
        } else {
            radii = [3000, 10000, 30000]
        }
        // Bound the entire radius expansion, not each of three requests independently.
        let deadline = Date().addingTimeInterval(12)
        for radius in radii {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= 1 else { throw SearchError.timeout }
            let serverTimeout = max(1, min(6, Int(remaining) - 1))
            let around: String
            if route.isEmpty {
                around = "around:\(radius),\(center.latitude),\(center.longitude)"
            } else {
                around = RouteSearchCorridor.around(route, radius: Double(radius))
            }
            let query = "[out:json][timeout:\(serverTimeout)];nwr\(intent.filter ?? "")(\(around));out center tags;"
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = min(8, remaining)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "data", value: query)]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SearchError.unavailable }
            guard (200...299).contains(http.statusCode) else { throw SearchError.httpStatus(http.statusCode) }
            let decoded = try JSONDecoder().decode(Reply.self, from: data)
            if let remark = decoded.remark {
                let message = remark.lowercased()
                throw message.contains("timeout") || message.contains("timed out")
                    ? SearchError.timeout : SearchError.unavailable
            }
            results = decoded.elements.compactMap { element in
                guard let lat = element.lat ?? element.center?.lat, let lon = element.lon ?? element.center?.lon,
                      (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                let coordinate = Coordinate(latitude: lat, longitude: lon)
                if route.isEmpty {
                    guard coordinate.distance(to: center) <= Double(radius) else { return nil }
                } else {
                    guard let projection = MapMatcher.project(coordinate, onto: route), projection.distanceFromRoute <= Double(radius) else { return nil }
                }
                let tags = element.tags ?? [:]
                let street = tags["addr:street"], number = tags["addr:housenumber"], city = tags["addr:city"]
                let address = [[street, number].compactMap { $0 }.joined(separator: " "), city ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                return SearchResult(destination: Destination(name: tags["name"] ?? tags["brand"] ?? intent.text.capitalized,
                                                              coordinate: coordinate, address: address.isEmpty ? nil : address),
                                    street: street, houseNumber: number, city: city, countryCode: tags["addr:country"],
                                    isPOI: true, osmID: "\(element.type):\(element.id)", category: tags["amenity"] ?? tags["shop"] ?? tags["tourism"],
                                    brand: tags["brand"], openingHours: tags["opening_hours"], phone: tags["phone"], website: tags["website"])
            }
            let namesByID = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                result.osmID.map { ($0, result.destination.name) }
            })
            await OpenStreetMapPlaceDetailsProvider.cacheSearchDetails(decoded.elements.compactMap { element in
                let id = "\(element.type):\(element.id)"
                guard let tags = element.tags, let name = namesByID[id] else { return nil }
                return (id: id, name: name, tags: tags)
            })
            // Expand only when this area is empty; a later network failure must not
            // discard nearby shops already found in the first radius.
            if !results.isEmpty { break }
        }
        return results
    }
    private struct Reply: Decodable { let elements: [Element]; let remark: String? }
    private struct Element: Decodable {
        let type: String; let id: Int64; let lat: Double?; let lon: Double?; let center: Center?; let tags: [String: String]?
    }
    private struct Center: Decodable { let lat: Double; let lon: Double }
}

extension ValhallaRouteProvider {
    struct MatrixCell: Decodable { let time: Double?; let distance: Double? }
    private struct MatrixReply: Decodable { let sources_to_targets: [[MatrixCell]] }

    func searchMatrix(sources: [Coordinate], targets: [Coordinate], mode: TransportMode,
                      preferences: RoutingPreferences) async throws -> [[MatrixCell]] {
        guard endpoint.scheme == "https", mode != .transit, mode != .parkRide else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("sources_to_targets"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["sources": sources.map { ["lat": $0.latitude, "lon": $0.longitude] },
                                      "targets": targets.map { ["lat": $0.latitude, "lon": $0.longitude] },
                                      "costing": mode.valhallaCosting, "units": "kilometers", "verbose": true]
        if mode == .car {
            var options: [String: Any] = [:]
            if preferences.avoidTolls { options["use_tolls"] = 0.0 }
            if preferences.avoidHighways { options["use_highways"] = 0.0 }
            if preferences.avoidFerries { options["use_ferry"] = 0.0 }
            if preferences.avoidUnpaved { options["exclude_unpaved"] = true }
            payload["costing_options"] = ["auto": options]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw RoutingError.invalidResponse }
        let rows = try JSONDecoder().decode(MatrixReply.self, from: data).sources_to_targets
        guard rows.count == sources.count, rows.allSatisfy({ $0.count == targets.count }) else { throw RoutingError.invalidResponse }
        return rows
    }
}
