import Foundation
import MapKit

enum NearbyPlaceCategory: String, CaseIterable, Identifiable {
    case fuel, food, parking, charging, parkRide

    var id: Self { self }
    var title: String {
        switch self {
        case .fuel: "Stacje paliw"
        case .food: "Jedzenie"
        case .parking: "Parkingi"
        case .charging: "Ładowarki EV"
        case .parkRide: "Parkingi P+R"
        }
    }
    var symbol: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .food: "fork.knife"
        case .parking, .parkRide: "parkingsign.circle.fill"
        case .charging: "bolt.car.fill"
        }
    }
    var fallbackName: String {
        switch self {
        case .fuel: "Stacja paliw"
        case .food: "Miejsce gastronomiczne"
        case .parking: "Parking"
        case .charging: "Stacja ładowania"
        case .parkRide: "Parking P+R"
        }
    }

    fileprivate var overpassFilter: String {
        switch self {
        case .fuel: "[amenity=fuel]"
        case .food: "[amenity~\"restaurant|fast_food|cafe\"]"
        case .parking: "[amenity=parking]"
        case .charging: "[amenity=charging_station]"
        case .parkRide: "[amenity=parking][park_ride=yes]"
        }
    }
}

struct NearbyPlaceCandidate: Identifiable {
    var id: String
    var destination: Destination
    var category: NearbyPlaceCategory
    var distanceFromRoute: Double
    var osmCategory: String? = nil
    var distanceToRoute: Double = 0
    var brand: String? = nil
    var operatorName: String? = nil
    var openingHours: String? = nil
    var countryCode: String? = nil
    var timeZoneIdentifier: String? = nil
    var fuelTypes: [String] = []
    var chargingStation: ChargingStationCapabilities? = nil
    var providerID: String? = nil

    var operatorOrBrand: String? {
        [operatorName, brand].compactMap { $0 }.first { $0 != destination.name }
    }

    @MainActor func openingHoursPresentation() async -> OpeningHoursPresentation? {
        guard let openingHours else { return nil }
        let resolvedTimeZoneIdentifier = self.timeZoneIdentifier
            ?? PlaceTimeZoneResolver.cachedIdentifier(for: destination.coordinate)
        guard let resolvedTimeZoneIdentifier else {
            return .unavailable(.timeZoneUnavailable)
        }
        return await PlaceOpeningHours(rawValue: openingHours,
                                       coordinate: destination.coordinate,
                                       countryCode: countryCode,
                                       timeZoneIdentifier: resolvedTimeZoneIdentifier).presentation()
    }

    var isOpen24Hours: Bool {
        openingHours?.trimmingCharacters(in: .whitespacesAndNewlines) == "24/7"
    }
}

enum ChargingStationAvailability: String {
    case available, unavailable, unknown
}

struct ChargingStationCapabilities {
    let connectorTypes: [String]
    let maximumPowerKW: Double?
    let chargingPointCount: Int?
    let publicAccess: Bool?
    let availability: ChargingStationAvailability
}

struct RouteStopSuggestion: Identifiable {
    var candidate: NearbyPlaceCandidate
    var detourSeconds: TimeInterval?
    var travelTime: TimeInterval? = nil
    var travelDistance: Double? = nil
    var estimateStatus: TravelEstimateStatus = .calculating
    var id: String { candidate.id }
}

enum NearbyPlaceError: LocalizedError {
    case unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unavailable: "Wyszukiwanie miejsc jest chwilowo niedostępne."
        case .invalidResponse: "Usługa miejsc zwróciła nieprawidłowe dane."
        }
    }
}

struct OpenStreetMapNearbyPlaceProvider {
    private let endpoint = URL(string: UserDefaults.standard.string(forKey: "overpassServer") ?? "https://overpass-api.de/api/interpreter")!

    func search(_ category: NearbyPlaceCategory, along route: [Coordinate], radius: Double = 900,
                resultLimit: Int = 25) async throws -> [NearbyPlaceCandidate] {
        guard route.count > 1 else { throw NearbyPlaceError.invalidResponse }
        return try await load(category, around: [route[0]], radius: radius,
                              referenceRoute: route, resultLimit: resultLimit)
    }

    func search(_ category: NearbyPlaceCategory, around coordinate: Coordinate, radius: Double = 2_000,
                resultLimit: Int = 25) async throws -> [NearbyPlaceCandidate] {
        try await load(category, around: [coordinate], radius: radius,
                       referenceRoute: nil, resultLimit: resultLimit)
    }

    private func load(_ category: NearbyPlaceCategory, around centers: [Coordinate], radius: Double,
                      referenceRoute: [Coordinate]?, resultLimit: Int) async throws -> [NearbyPlaceCandidate] {
        let area: String
        if let referenceRoute {
            area = RouteSearchCorridor.around(referenceRoute, radius: radius)
        } else {
            let center = centers[0]
            area = "around:\(Int(radius)),\(center.latitude),\(center.longitude)"
        }
        let query = "[out:json][timeout:10];nwr\(category.overpassFilter)(\(area));out center tags;"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NearbyPlaceError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw NearbyPlaceError.unavailable }
            data = responseData
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NearbyPlaceError {
            throw error
        } catch {
            throw NearbyPlaceError.unavailable
        }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw NearbyPlaceError.invalidResponse }

        try Task.checkCancellation()
        guard decoded.remark == nil else { throw NearbyPlaceError.unavailable }
        var found: [NearbyPlaceCandidate] = []
        for element in decoded.elements {
            guard let coordinate = element.coordinate else { continue }
            let pathDistance: Double
            let routeDistance: Double
            if let referenceRoute {
                guard let projection = MapMatcher.project(coordinate, onto: referenceRoute),
                      projection.distanceFromRoute <= radius else { continue }
                pathDistance = projection.alongRoute
                routeDistance = projection.distanceFromRoute
            } else {
                guard let center = centers.first, coordinate.distance(to: center) <= radius else { continue }
                pathDistance = coordinate.distance(to: centers[0])
                routeDistance = pathDistance
            }
            let tags = element.tags ?? [:]
            let name = tags["name"] ?? tags["brand"] ?? tags["operator"] ?? category.fallbackName
            let id = "\(element.type ?? "poi")-\(element.id)"
            let poiMetadata = element.type.map {
                POIMetadata(provider: .openStreetMap, osmID: "\($0):\(element.id)",
                            category: tags["amenity"] ?? tags["shop"] ?? tags["tourism"],
                            brand: tags["brand"], operatorName: tags["operator"])
            }
            let destination = Destination(name: name, coordinate: coordinate,
                                          address: [tags["addr:street"], tags["addr:housenumber"]]
                                            .compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                                          poi: poiMetadata)
            found.append(NearbyPlaceCandidate(id: id, destination: destination,
                                               category: category, distanceFromRoute: pathDistance,
                                               osmCategory: tags["amenity"] ?? tags["shop"],
                                               distanceToRoute: routeDistance,
                                               brand: tags["brand"],
                                               operatorName: tags["operator"],
                                               openingHours: tags["opening_hours"],
                                               countryCode: Self.countryCode(from: tags),
                                               fuelTypes: category == .fuel ? Self.fuelTypes(from: tags) : [],
                                               chargingStation: category == .charging
                                                   ? Self.chargingCapabilities(from: tags) : nil))
        }
        var unique: [NearbyPlaceCandidate]
        if category == .charging, let referenceRoute, resultLimit > 25 {
            let routeLength = zip(referenceRoute, referenceRoute.dropFirst())
                .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            unique = Self.distributedRouteCandidates(found, routeLength: routeLength,
                                                     resultLimit: resultLimit)
        } else {
            var nearby: [NearbyPlaceCandidate] = []
            for candidate in found.sorted(by: { $0.distanceFromRoute < $1.distanceFromRoute }) {
                guard !nearby.contains(where: {
                    $0.destination.coordinate.distance(to: candidate.destination.coordinate) < 15
                }) else { continue }
                nearby.append(candidate)
                if nearby.count >= max(1, min(resultLimit, 1_000)) { break }
            }
            unique = nearby
        }
        if unique.contains(where: { $0.openingHours != nil }) {
            let timezoneCoordinate = referenceRoute == nil ? centers.first : unique.first(where: { $0.openingHours != nil })?.destination.coordinate
            let timezoneReuseRadius = referenceRoute == nil ? min(radius, 5_000) : 1_000
            if let timezoneCoordinate,
               let timeZoneIdentifier = await PlaceTimeZoneResolver.identifier(for: timezoneCoordinate) {
                unique = unique.map { candidate in
                    guard candidate.openingHours != nil,
                          candidate.destination.coordinate.distance(to: timezoneCoordinate) <= timezoneReuseRadius else { return candidate }
                    var value = candidate
                    value.timeZoneIdentifier = timeZoneIdentifier
                    return value
                }
            }
        }
        let namesByID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0.destination.name) })
        await OpenStreetMapPlaceDetailsProvider.cacheSearchDetails(decoded.elements.compactMap { element in
            guard let type = element.type, let tags = element.tags,
                  let name = namesByID["\(type)-\(element.id)"] else { return nil }
            return (id: "\(type):\(element.id)", name: name, tags: tags)
        })
        return unique
    }

    static func distributedRouteCandidates(_ candidates: [NearbyPlaceCandidate],
                                           routeLength: Double,
                                           resultLimit: Int) -> [NearbyPlaceCandidate] {
        let limit = max(1, min(resultLimit, 1_000))
        let bucketCount = min(100, max(1, (limit + 9) / 10))
        let candidatesPerBucket = (limit + bucketCount - 1) / bucketCount
        let length = routeLength.isFinite ? max(1, routeLength) : 1
        let ordered = candidates.sorted { lhs, rhs in
            func hasUsableChargingData(_ candidate: NearbyPlaceCandidate) -> Bool {
                guard let station = candidate.chargingStation else { return false }
                return station.availability != .unavailable && station.publicAccess != false
                    && (station.maximumPowerKW ?? 0) > 0 && !station.connectorTypes.isEmpty
            }
            let lhsUsable = hasUsableChargingData(lhs)
            let rhsUsable = hasUsableChargingData(rhs)
            if lhsUsable != rhsUsable { return lhsUsable }
            let lhsPower = lhs.chargingStation?.maximumPowerKW ?? 0
            let rhsPower = rhs.chargingStation?.maximumPowerKW ?? 0
            if lhsPower != rhsPower { return lhsPower > rhsPower }
            if lhs.distanceToRoute != rhs.distanceToRoute {
                return lhs.distanceToRoute < rhs.distanceToRoute
            }
            if lhs.distanceFromRoute != rhs.distanceFromRoute {
                return lhs.distanceFromRoute < rhs.distanceFromRoute
            }
            return lhs.id < rhs.id
        }

        var bucketCounts = Array(repeating: 0, count: bucketCount)
        var selected: [NearbyPlaceCandidate] = []
        for candidate in ordered {
            let progress = candidate.distanceFromRoute.isFinite
                ? min(length, max(0, candidate.distanceFromRoute)) : 0
            let bucket = min(bucketCount - 1, Int(progress / length * Double(bucketCount)))
            guard bucketCounts[bucket] < candidatesPerBucket,
                  !selected.contains(where: {
                      $0.destination.coordinate.distance(to: candidate.destination.coordinate) < 15
                  }) else { continue }
            selected.append(candidate)
            bucketCounts[bucket] += 1
            if selected.count >= limit { break }
        }
        return selected.sorted { $0.distanceFromRoute < $1.distanceFromRoute }
    }

    private static func fuelTypes(from tags: [String: String]) -> [String] {
        tags.compactMap { entry -> String? in
            let (key, value) = entry
            guard key.hasPrefix("fuel:"), value.lowercased() != "no" else { return nil }
            return String(key.dropFirst("fuel:".count))
        }.sorted()
    }

    private static func countryCode(from tags: [String: String]) -> String? {
        guard let value = tags["addr:country"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 2, value.allSatisfy(\.isLetter) else { return nil }
        return value.lowercased()
    }

    private static func chargingCapabilities(from tags: [String: String]) -> ChargingStationCapabilities {
        let connectors = Set(tags.compactMap { entry -> String? in
            let (key, value) = entry
            guard key.hasPrefix("socket:"), value != "no", value != "0",
                  !key.contains("output"), !key.contains("voltage"), !key.contains("current") else { return nil }
            let connector = key.split(separator: ":").dropFirst().first.map(String.init) ?? ""
            return connector.isEmpty ? nil : connector.lowercased()
        })
        let outputValues = tags.filter { $0.key.contains("output") || $0.key == "charging_station:output" }
            .values.flatMap { value -> [Double] in
                let pattern = #"[0-9]+(?:[.,][0-9]+)?"#
                guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
                let source = value.replacingOccurrences(of: ",", with: ".")
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                return expression.matches(in: source, range: range).compactMap { match in
                    guard let range = Range(match.range, in: source), let number = Double(source[range]) else { return nil }
                    return source.lowercased().contains("kw") ? number : number / 1_000
                }
            }
        let maximumPower = outputValues.filter { $0 > 0 && $0 <= 1_000 }.max()
        let chargingPointCount = [tags["charging_station:capacity"], tags["capacity"]]
            .compactMap { $0 }
            .compactMap(Int.init)
            .first { $0 > 0 }
        let access = tags["access"]?.lowercased()
        let publicAccess: Bool? = {
            guard let access else { return nil }
            return ["yes", "public", "permissive"].contains(access)
        }()
        let operational = tags["operational_status"]?.lowercased() ?? tags["operational"]?.lowercased()
        let availability: ChargingStationAvailability
        if let operational, ["no", "broken", "closed", "out_of_order"].contains(operational) {
            availability = .unavailable
        } else if let operational, ["yes", "operational", "open"].contains(operational) {
            availability = .available
        } else {
            availability = .unknown
        }
        return ChargingStationCapabilities(connectorTypes: connectors.sorted(),
                                           maximumPowerKW: maximumPower,
                                           chargingPointCount: chargingPointCount,
                                           publicAccess: publicAccess,
                                           availability: availability)
    }

    private struct Response: Decodable { let elements: [Element]; let remark: String? }
    private struct Element: Decodable {
        let id: Int64
        let type: String?
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

struct NearbyPlaceSearchProvider {
    func search(_ category: NearbyPlaceCategory, around coordinate: Coordinate,
                radius: Double, resultLimit: Int) async throws -> [NearbyPlaceCandidate] {
        var openStreetMapError: Error?
        do {
            let candidates = try await OpenStreetMapNearbyPlaceProvider()
                .search(category, around: coordinate, radius: radius, resultLimit: resultLimit)
            if !candidates.isEmpty { return candidates }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            openStreetMapError = error
        }

        try Task.checkCancellation()
        do {
            let candidates = try await MapKitNearbyPlaceProvider()
                .search(category, around: coordinate, radius: radius, resultLimit: resultLimit)
            if candidates.isEmpty, let openStreetMapError { throw openStreetMapError }
            return candidates
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let openStreetMapError { throw openStreetMapError }
            throw NearbyPlaceError.unavailable
        }
    }
}

struct MapKitNearbyPlaceProvider {
    func search(_ category: NearbyPlaceCategory, around coordinate: Coordinate,
                radius: Double, resultLimit: Int) async throws -> [NearbyPlaceCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.mapKitSearchQuery
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.mapKitCategories)
        request.region = MKCoordinateRegion(center: coordinate.cl,
                                            latitudinalMeters: radius * 2,
                                            longitudinalMeters: radius * 2)
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await search.start()
        } onCancel: {
            Task { @MainActor in search.cancel() }
        }
        try Task.checkCancellation()

        let candidates = response.mapItems.compactMap { item -> NearbyPlaceCandidate? in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            if category == .parkRide, !Self.isParkAndRide(name) { return nil }

            let location = item.location
            let candidateCoordinate = Coordinate(latitude: location.coordinate.latitude,
                                                 longitude: location.coordinate.longitude)
            let distance = coordinate.distance(to: candidateCoordinate)
            guard distance <= radius else { return nil }

            let address = [item.address?.shortAddress, item.address?.fullAddress]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let providerID = item.identifier?.rawValue
            let categoryValue = item.pointOfInterestCategory?.rawValue
            let destination = Destination(
                name: name,
                coordinate: candidateCoordinate,
                address: address,
                poi: POIMetadata(provider: .mapKit, category: categoryValue))
            let id = providerID.map { "mapkit-\($0)" }
                ?? "mapkit-\(candidateCoordinate.latitude)-\(candidateCoordinate.longitude)"
            return NearbyPlaceCandidate(id: id, destination: destination,
                                        category: category, distanceFromRoute: distance,
                                        osmCategory: categoryValue,
                                        timeZoneIdentifier: item.timeZone?.identifier,
                                        providerID: providerID)
        }

        var unique: [NearbyPlaceCandidate] = []
        for candidate in candidates.sorted(by: { $0.distanceFromRoute < $1.distanceFromRoute }) {
            guard !unique.contains(where: {
                $0.destination.coordinate.distance(to: candidate.destination.coordinate) < 15
            }) else { continue }
            unique.append(candidate)
            if unique.count >= max(1, min(resultLimit, 100)) { break }
        }
        return unique
    }

    private static func isParkAndRide(_ name: String) -> Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return normalized.contains("p r") || normalized.contains("park and ride")
            || normalized.contains("parkuj i jedz")
    }
}

fileprivate extension NearbyPlaceCategory {
    var mapKitSearchQuery: String {
        switch self {
        case .fuel: "gas station"
        case .food: "food"
        case .parking: "parking"
        case .charging: "EV charging station"
        case .parkRide: "park and ride"
        }
    }

    var mapKitCategories: [MKPointOfInterestCategory] {
        switch self {
        case .fuel: [.gasStation]
        case .food: [.restaurant, .cafe, .bakery]
        case .parking, .parkRide: [.parking]
        case .charging: [.evCharger]
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Keep a continuous corridor while bounding simplification error by distance,
/// rather than skipping a fixed number of vertices on long routes.
enum RouteSearchCorridor {
    static func around(_ route: [Coordinate], radius: Double) -> String {
        guard let first = route.first else { return "" }
        var samples = [first]
        for index in route.indices.dropFirst() {
            let start = route[index - 1]
            let end = route[index]
            let segmentLength = start.distance(to: end)
            let pieces = max(1, Int(ceil(segmentLength / 500)))
            guard pieces > 1 else {
                samples.append(end)
                continue
            }
            for piece in 1...pieces {
                let fraction = Double(piece) / Double(pieces)
                samples.append(Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                                          longitude: start.longitude + (end.longitude - start.longitude) * fraction))
            }
        }
        return "around:\(Int(radius + 500))," + samples.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ",")
    }
}
