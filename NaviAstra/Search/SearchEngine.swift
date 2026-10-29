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
    var parcelQuery: ParcelPOI.Query? = nil
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
        if let parcel = classifyParcel(clean, alongRoute: along) { return parcel }
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

    private func classifyParcel(_ text: String, alongRoute: Bool) -> ClassifiedQuery? {
        if let reference = ParcelPOI.reference(in: text) {
            return ClassifiedQuery(intent: .category, text: reference, alongRoute: alongRoute,
                                   parcelQuery: ParcelPOI.Query(reference: reference))
        }
        let categories: [(String, ParcelPOI.Scope)] = [
            ("paczkomaty i punkty odbioru", .all), ("automaty paczkowe", .lockers),
            ("automat paczkowy", .lockers), ("punkty odbioru", .pickup),
            ("punkt odbioru", .pickup),
            ("paczkomaty", .lockers), ("paczkomat", .lockers),
            ("paczkopunkty", .pickup), ("paczkopunkt", .pickup)
        ]
        func hasPrefix(_ value: String, _ prefix: String) -> Bool {
            value == prefix || value.hasPrefix(prefix + " ") || value.hasPrefix(prefix + ",")
        }
        let category = categories.first { hasPrefix(text, $0.0) }
        let remainder = category.map {
            String(text.dropFirst($0.0.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        } ?? text
        for carrier in ParcelPOI.operators {
            guard let alias = carrier.aliases.first(where: { hasPrefix(remainder, $0) }) else { continue }
            var suffix = String(remainder.dropFirst(alias.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            var scope = category?.1 ?? .all
            if category == nil {
                if alias.range(of: "station|box|automat|locker|packstation", options: .regularExpression) != nil { scope = .lockers }
                else if alias.range(of: "punkt|pop|parcelshop|access point", options: .regularExpression) != nil { scope = .pickup }
            }
            if let trailingCategory = categories.first(where: { hasPrefix(suffix, $0.0) }) {
                scope = trailingCategory.1
                suffix = String(suffix.dropFirst(trailingCategory.0.count))
            }
            let reference = ParcelPOI.reference(in: suffix, explicitOperator: true)
            let location = reference == nil ? locationSuffix(suffix) : ""
            return ClassifiedQuery(intent: .brand, text: carrier.title,
                                   location: location.isEmpty ? nil : location, alongRoute: alongRoute,
                                   parcelQuery: ParcelPOI.Query(scope: scope, operatorPattern: carrier.pattern,
                                                               reference: reference))
        }
        guard let category else { return nil }
        let reference = ParcelPOI.reference(in: remainder, explicitOperator: true)
        let location = reference == nil ? locationSuffix(remainder) : ""
        let title = category.1 == .lockers ? "Paczkomaty" : category.1 == .pickup ? "Punkty odbioru" : "Paczkomaty i punkty odbioru"
        return ClassifiedQuery(intent: .category, text: title,
                               location: location.isEmpty ? nil : location, alongRoute: alongRoute,
                               parcelQuery: ParcelPOI.Query(scope: category.1, reference: reference))
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
                onUpdate: @escaping @MainActor ([SearchResult]) -> Void = { _ in }) async throws -> [SearchResult] {
        let intent = QueryClassifier().classify(query)
        if intent.alongRoute && context.route.count < 2 { throw SearchError.noActiveRoute }
        var center = context.area ?? context.origin
        if let location = intent.location {
            center = try await resolve(location, near: center)
        }
        let searchCenter = center
        let routeOrigin = context.origin ?? searchCenter
        let progressive: ProgressiveSearchEstimates?
        if (intent.intent == .brand || intent.intent == .category), !intent.alongRoute,
           context.mode != .transit, let origin = routeOrigin {
            progressive = ProgressiveSearchEstimates(intent: intent, context: context, resolver: { targets in
                var coordinates: [Coordinate] = []
                for result in targets {
                    let destination = result.navigationDestination
                    let access = await POIAccessResolver.shared.cachedTarget(for: destination, mode: context.mode)
                    coordinates.append(access?.coordinate ?? destination.coordinate)
                }
                let rows = try await matrix.searchMatrix(sources: [origin], targets: coordinates,
                    mode: context.mode, preferences: context.preferences)
                guard let row = rows.first else { return [:] }
                var values: [String: ProgressiveSearchEstimates.Estimate] = [:]
                for index in targets.indices where row.indices.contains(index) {
                    if let time = row[index].time, let distance = row[index].distance {
                        values[targets[index].placeIdentity.cacheKey] = .init(time: time, distance: distance * 1_000)
                    }
                }
                return values
            }, onUpdate: onUpdate)
        } else { progressive = nil }
        defer { progressive?.cancel() }
        // The suffix is part of the request, not only a geocoding hint. Searching
        // just "BP" loses the street even when the provider knows its address.
        let providerQuery = [intent.text, intent.location].compactMap { $0 }.joined(separator: ", ")
        // Publish provider replies before waiting for other sources or route estimates.
        let publishCandidates: ([SearchResult]) -> Void = { candidates in
            let ranked = Array(SearchDeduplicator.mergeAndRank(
                candidates, intent: intent, context: context,
                searchCenter: searchCenter, routeOrigin: routeOrigin).prefix(progressive == nil ? 8 : 16))
            if let progressive { progressive.publish(ranked) }
            else { onUpdate(ranked) }
        }
        var candidates: [SearchResult]
        if let coordinate = intent.coordinate {
            candidates = [SearchResult(
                destination: Destination(name: query, coordinate: coordinate),
                street: nil, houseNumber: nil, city: nil, countryCode: nil)]
        } else if let parcelQuery = intent.parcelQuery, let reference = parcelQuery.reference {
            var requests: [SearchProviderBatch.Request] = []
            if InPostPointProvider.canSearch(reference, query: parcelQuery) {
                requests.append(.init(authoritative: true) {
                    let results = try await InPostPointProvider().search(reference)
                    return results.filter { parcelQuery.matches($0) }
                })
            }
            requests.append(.init {
                try await poi.search(intent, near: searchCenter, route: intent.alongRoute ? context.route : [])
            })
            candidates = try await SearchProviderBatch.search(requests, onUpdate: publishCandidates)
        } else if intent.intent == .address {
            candidates = try await AddressSearchProvider().search(intent.text, near: searchCenter,
                                                                  includeUUGFallback: includeUUGFallback,
                                                                  onUpdate: publishCandidates)
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
                try await photon.search(providerQuery, near: searchCenter, addressesOnly: false, osmTag: photonTag)
            })
            requests.append(.init {
                try await MapKitSearchProvider().search(providerQuery, near: searchCenter)
            })
            if ContactsAccessStatus.current().canReadContacts {
                requests.append(.init {
                    try await ContactsSearchProvider().search(query, near: searchCenter)
                })
            }
            do {
                candidates = try await SearchProviderBatch.search(requests, onUpdate: publishCandidates)
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
        // Transit needs a full journey plan per result, so only plan the visible rows.
        let candidateLimit = intent.alongRoute && context.mode != .transit ? 20 : progressive == nil ? 8 : 16
        var results = Array(SearchDeduplicator.mergeAndRank(
            candidates, intent: intent, context: context,
            searchCenter: searchCenter, routeOrigin: routeOrigin).prefix(candidateLimit))
        if let progressive {
            results = await progressive.complete(results)
        } else if let origin = routeOrigin, !results.isEmpty {
            onUpdate(Array(results.prefix(8)))
            if context.mode == .transit {
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
                // List estimates use known access points only. Fetch entrances/parking when
                // a destination is selected, instead of serializing Overpass for every row.
                var routedTargets: [(index: Int, coordinate: Coordinate)] = []
                for index in results.indices {
                    try Task.checkCancellation()
                    let destination = results[index].navigationDestination
                    let target = await POIAccessResolver.shared.cachedTarget(for: destination, mode: context.mode)
                    routedTargets.append((index, target?.coordinate ?? destination.coordinate))
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
                            // A failed matrix must not fan out into up to eight sequential
                            // full route requests to the same unavailable service.
                            results[target.index].travelEstimateStatus = .unavailable
                        }
                        onUpdate(Array(results.prefix(8)))
                    }
                    if intent.alongRoute, rows != nil, let routeTarget = context.routeTarget {
                        // Compare the same routing model on both sides; never subtract a stale live ETA.
                        do {
                            let onward = try await matrix.searchMatrix(sources: [origin] + coordinates,
                                targets: [routeTarget], mode: context.mode, preferences: context.preferences)
                            if let baseline = onward.first?.first?.time, baseline.isFinite, baseline >= 0 {
                                for (rowIndex, target) in routedTargets.enumerated() where onward.indices.contains(rowIndex + 1) {
                                    if let first = results[target.index].travelTime,
                                       let second = onward[rowIndex + 1].first?.time, second.isFinite, second >= 0 {
                                        results[target.index].detour = max(0, first + second - baseline)
                                    }
                                }
                            }
                        } catch {
                            try Task.checkCancellation()
                            // An optional detour estimate must never discard places and
                            // travel times already obtained from the first matrix.
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        results.sort { a, b in
            SearchRanking.precedes(a, b, intent: intent, context: context, withTravelEstimates: true)
        }
        let visibleResults = Array(results.prefix(8))
        onUpdate(visibleResults)
        return visibleResults
    }

    private func resolve(_ location: String, near center: Coordinate?) async throws -> Coordinate {
        let requests: [SearchProviderBatch.Request] = [
            .init {
                try await photon.search(location, near: center, addressesOnly: false)
            },
            .init {
                try await MapKitSearchProvider().search(location, near: center)
            }
        ]
        let results = try await SearchProviderBatch.search(requests, onUpdate: { _ in })
        // A street name can exist in several cities. Wait for both sources and
        // prefer matching nearby locations instead of whichever provider wins.
        let ranked = results.sorted { lhs, rhs in
            let leftMatch = SearchRanking.locationMatch(lhs, location: location)
            let rightMatch = SearchRanking.locationMatch(rhs, location: location)
            if leftMatch != rightMatch { return leftMatch > rightMatch }
            if let center {
                let leftDistance = center.distance(to: lhs.destination.coordinate)
                let rightDistance = center.distance(to: rhs.destination.coordinate)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
            }
            return SearchRanking.normalizedIdentity(lhs.destination.name)
                < SearchRanking.normalizedIdentity(rhs.destination.name)
        }
        guard let coordinate = ranked.first?.destination.coordinate else {
            throw SearchError.locationNotFound(location)
        }
        return coordinate
    }
}

struct POISearchProvider {
    var endpoint = MapRoadPOIEndpoint.url

    func search(_ intent: ClassifiedQuery, near center: Coordinate?, route: [Coordinate]) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        let radii: [Int]
        if intent.parcelQuery?.reference != nil {
            radii = [0]
        } else if !route.isEmpty {
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
            if intent.parcelQuery?.reference != nil {
                around = ""
            } else if route.isEmpty {
                guard let center else { throw SearchError.locationRequired }
                around = "around:\(radius),\(center.latitude),\(center.longitude)"
            } else {
                around = RouteSearchCorridor.around(route, radius: Double(radius))
            }
            let selectors = intent.parcelQuery?.selectors(around: around)
                ?? "nwr\(intent.filter ?? "")(\(around));"
            let query = "[out:json][timeout:\(serverTimeout)];\(selectors)out center tags;"
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = min(8, remaining)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "data", value: query)]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            let (data, response) = try await OSMRequestTransport.shared.data(for: request, priority: true,
                                                                          maximumDuration: remaining)
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
                if intent.parcelQuery?.reference != nil {
                    if !route.isEmpty {
                        guard let projection = MapMatcher.project(coordinate, onto: route),
                              projection.distanceFromRoute <= 1_500 else { return nil }
                    }
                } else if route.isEmpty {
                    guard let center else { return nil }
                    guard coordinate.distance(to: center) <= Double(radius) else { return nil }
                } else {
                    guard let projection = MapMatcher.project(coordinate, onto: route), projection.distanceFromRoute <= Double(radius) else { return nil }
                }
                let tags = element.tags ?? [:]
                let street = tags["addr:street"], number = tags["addr:housenumber"], city = tags["addr:city"]
                let address = [[street, number].compactMap { $0 }.joined(separator: " "), city ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                return SearchResult(destination: Destination(name: ParcelPOI.name(tags: tags, fallback: intent.text.capitalized, includePickupServices: intent.parcelQuery != nil),
                                                              coordinate: coordinate, address: address.isEmpty ? nil : address),
                                    street: street, houseNumber: number, city: city, countryCode: tags["addr:country"],
                                    isPOI: true, osmID: "\(element.type):\(element.id)", category: ParcelPOI.category(tags: tags, includePickupServices: intent.parcelQuery != nil) ?? tags["amenity"] ?? tags["shop"] ?? tags["tourism"],
                                    brand: ParcelPOI.brand(tags: tags, includePickupServices: intent.parcelQuery != nil), operatorName: ParcelPOI.operatorName(tags: tags, includePickupServices: intent.parcelQuery != nil),
                                    parcelReferences: ParcelPOI.category(tags: tags) == nil ? [] : ParcelPOI.references(tags: tags),
                                    openingHours: ParcelPOI.openingHours(tags: tags, includePickupServices: intent.parcelQuery != nil),
                                    phone: tags["contact:phone"] ?? tags["phone"],
                                    website: tags["contact:website"] ?? tags["website"])
            }
            if let parcelQuery = intent.parcelQuery {
                results = results.filter { parcelQuery.matches($0) }
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
        guard endpoint.scheme == "https", mode != .transit else { throw RoutingError.invalidEndpoint }
        var request = URLRequest(url: endpoint.appendingPathComponent("sources_to_targets"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra", forHTTPHeaderField: "X-Client-Id")
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
        try preferences.applyValhallaOptions(to: &payload, mode: mode)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: endpoint)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ValhallaServices.validate(data: data, response: response)
        let rows = try JSONDecoder().decode(MatrixReply.self, from: data).sources_to_targets
        guard rows.count == sources.count, rows.allSatisfy({ $0.count == targets.count }) else { throw RoutingError.invalidResponse }
        return rows
    }
}
