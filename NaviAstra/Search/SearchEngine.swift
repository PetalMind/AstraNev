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
    nonisolated static func normalize(_ text: String) -> String {
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
                                   filter: "[~\"^(brand|name|operator)$\"~\"^\(pattern)($|[ ;])\",i]",
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

    func search(_ query: String, context: SearchContext, includeUUGFallback: Bool = false,
                routeEstimator: SearchRouteEstimator = { _, _, _ in nil },
                onUpdate: @MainActor ([SearchResult]) -> Void = { _ in }) async throws -> [SearchResult] {
        let intent = QueryClassifier().classify(query)
        if intent.alongRoute && context.route.count < 2 { throw SearchError.noActiveRoute }
        var center = context.area ?? context.origin
        if let location = intent.location {
            center = try await resolve(location, near: center)
        }
        let searchCenter = center
        let routeOrigin = context.origin ?? searchCenter
        var candidates: [SearchResult]
        if let coordinate = intent.coordinate {
            candidates = [SearchResult(
                destination: Destination(name: query, coordinate: coordinate),
                street: nil, houseNumber: nil, city: nil, countryCode: nil)]
        } else if intent.intent == .address {
            candidates = try await AddressSearchProvider().search(intent.text, near: searchCenter,
                                                                  includeUUGFallback: includeUUGFallback,
                                                                  onUpdate: { _ in })
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
            if ContactsAccessStatus.current().canReadContacts {
                requests.append(.init {
                    try await ContactsSearchProvider().search(query, near: searchCenter)
                })
            }
            do {
                candidates = try await SearchProviderBatch.search(requests, onUpdate: { _ in })
            } catch {
                try Task.checkCancellation()
                guard includeUUGFallback, intent.intent == .place else { throw error }
                let fallback = await GUGiKAddressProvider().search(intent.text)
                guard !fallback.isEmpty else { throw error }
                candidates = fallback
            }
            if includeUUGFallback, intent.intent == .place, candidates.isEmpty {
                candidates = await GUGiKAddressProvider().search(intent.text)
            }
        }
        try Task.checkCancellation()
        // Along-route road searches retain extra candidates to compare detours.
        // Transit and P+R need a full journey plan per result, so only plan the visible rows.
        let candidateLimit = intent.alongRoute && context.mode != .transit && context.mode != .parkRide ? 20 : 8
        var results = Array(SearchDeduplicator.mergeAndRank(
            candidates, intent: intent, context: context,
            searchCenter: searchCenter, routeOrigin: routeOrigin).prefix(candidateLimit))
        if let origin = routeOrigin, !results.isEmpty {
            if context.mode == .transit || context.mode == .parkRide {
                for index in results.indices {
                    try Task.checkCancellation()
                    do {
                        if let estimate = try await routeEstimator(
                            origin, results[index].navigationDestination, context.mode),
                           estimate.travelTime.isFinite, estimate.travelTime >= 0,
                           estimate.distanceMeters.isFinite, estimate.distanceMeters >= 0 {
                            results[index].travelTime = estimate.travelTime
                            results[index].travelDistance = estimate.distanceMeters
                            results[index].travelEstimateStatus = .notRequested
                        } else {
                            results[index].travelEstimateStatus = .unavailable
                        }
                    } catch {
                        try Task.checkCancellation()
                        results[index].travelEstimateStatus = .unavailable
                    }
                    onUpdate(Array(results.prefix(8)))
                }
            } else {
                let poiIndexes = results.indices.filter { results[$0].isPOI }
                let poiDestinations = poiIndexes.map { results[$0].navigationDestination }
                let resolvedPOIs = await POIAccessResolver.shared.resolveMany(for: poiDestinations, mode: context.mode)
                try Task.checkCancellation()
                var poiCoordinates: [Int: Coordinate] = [:]
                for (offset, index) in poiIndexes.enumerated() {
                    if let target = resolvedPOIs[offset] {
                        poiCoordinates[index] = target.coordinate
                    } else {
                        // Valhalla snaps the POI pin to its routable road point when OSM has no
                        // explicit entrance or parking access point available.
                        poiCoordinates[index] = results[index].destination.coordinate
                    }
                }
                let routedTargets: [(index: Int, coordinate: Coordinate)] = results.indices.compactMap { index in
                    if results[index].isPOI {
                        guard let coordinate = poiCoordinates[index] else { return nil }
                        return (index, coordinate)
                    }
                    return (index, results[index].destination.coordinate)
                }
                if !routedTargets.isEmpty {
                    let coordinates = routedTargets.map { $0.coordinate }
                    let rows: [[ValhallaRouteProvider.MatrixCell]]?
                    do {
                        rows = try await matrix.searchMatrix(sources: [origin], targets: coordinates,
                                                             mode: context.mode, preferences: context.preferences)
                    } catch {
                        try Task.checkCancellation()
                        rows = nil
                    }
                    for (rowIndex, target) in routedTargets.enumerated() {
                        let cell: ValhallaRouteProvider.MatrixCell?
                        if let firstRow = rows?.first, firstRow.indices.contains(rowIndex) {
                            cell = firstRow[rowIndex]
                        } else {
                            cell = nil
                        }
                        if let time = cell?.time, time.isFinite, time >= 0,
                           let distance = cell?.distance, distance.isFinite, distance >= 0 {
                            results[target.index].travelTime = time
                            results[target.index].travelDistance = distance * 1_000
                            results[target.index].travelEstimateStatus = .notRequested
                        } else {
                            do {
                                if let route = try await matrix.calculateRoutes(
                                    from: origin, to: target.coordinate, through: [], mode: context.mode,
                                    preferences: context.preferences, avoiding: []).first {
                                    results[target.index].travelTime = route.expectedTravelTime
                                    results[target.index].travelDistance = route.distance
                                    results[target.index].travelEstimateStatus = .notRequested
                                } else {
                                    results[target.index].travelEstimateStatus = .unavailable
                                }
                            } catch {
                                try Task.checkCancellation()
                                results[target.index].travelEstimateStatus = .unavailable
                            }
                        }
                        onUpdate(Array(results.prefix(8)))
                    }
                    if intent.alongRoute, let routeTarget = context.routeTarget {
                        // Compare the same routing model on both sides; never subtract a stale live ETA.
                        let onward = try await matrix.searchMatrix(sources: [origin] + coordinates,
                                                                    targets: [routeTarget], mode: context.mode,
                                                                    preferences: context.preferences)
                        if let baseline = onward[0][0].time {
                            for (rowIndex, target) in routedTargets.enumerated() {
                                if let first = results[target.index].travelTime,
                                   let second = onward[rowIndex + 1][0].time {
                                    results[target.index].detour = max(0, first + second - baseline)
                                }
                            }
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        results.sort { a, b in
            // Along-route results minimize added journey time; other searches keep text relevance first.
            if a.isContact != b.isContact { return a.isContact }
            let aTime = intent.alongRoute ? a.detour : a.travelTime
            let bTime = intent.alongRoute ? b.detour : b.travelTime
            let aRelevance = SearchRanking.relevance(a, intent: intent)
            let bRelevance = SearchRanking.relevance(b, intent: intent)
            if intent.alongRoute, aTime != bTime { return (aTime ?? .infinity) < (bTime ?? .infinity) }
            if aRelevance != bRelevance { return aRelevance > bRelevance }
            if !intent.alongRoute, aTime != bTime { return (aTime ?? .infinity) < (bTime ?? .infinity) }
            let aLocal = context.localDestinations.contains { $0.coordinate.distance(to: a.destination.coordinate) < 20 }
            let bLocal = context.localDestinations.contains { $0.coordinate.distance(to: b.destination.coordinate) < 20 }
            if aLocal != bLocal { return aLocal }
            return (a.straightDistance ?? .infinity) < (b.straightDistance ?? .infinity)
        }
        let visibleResults = Array(results.prefix(8))
        onUpdate(visibleResults)
        return visibleResults
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
    var endpoint = MapRoadPOIEndpoint.url

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
            let (data, response) = try await OSMRequestTransport.shared.data(for: request, priority: true)
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
                                    brand: tags["brand"], operatorName: tags["operator"],
                                    openingHours: tags["opening_hours"],
                                    phone: tags["contact:phone"] ?? tags["phone"],
                                    website: tags["contact:website"] ?? tags["website"])
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
