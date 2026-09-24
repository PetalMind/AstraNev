import Foundation

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
    var fuelTypes: [String] = []
    var chargingStation: ChargingStationCapabilities? = nil

    var operatorOrBrand: String? {
        [operatorName, brand].compactMap { $0 }.first { $0 != destination.name }
    }

    var isOpenNow: Bool? {
        guard let openingHours else { return nil }
        return PlaceOpeningHours(rawValue: openingHours).isOpen()
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
        case .unavailable: "Wyszukiwanie miejsc w OpenStreetMap jest chwilowo niedostępne."
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
            let destination = Destination(name: name, coordinate: coordinate,
                                          address: [tags["addr:street"], tags["addr:housenumber"]]
                                            .compactMap { $0 }.joined(separator: " ").nilIfEmpty)
            found.append(NearbyPlaceCandidate(id: id, destination: destination,
                                               category: category, distanceFromRoute: pathDistance,
                                               osmCategory: tags["amenity"] ?? tags["shop"],
                                               distanceToRoute: routeDistance,
                                               brand: tags["brand"],
                                               operatorName: tags["operator"],
                                               openingHours: tags["opening_hours"],
                                               fuelTypes: category == .fuel ? Self.fuelTypes(from: tags) : [],
                                               chargingStation: category == .charging
                                                   ? Self.chargingCapabilities(from: tags) : nil))
        }
        var unique: [NearbyPlaceCandidate] = []
        for candidate in found.sorted(by: { $0.distanceFromRoute < $1.distanceFromRoute }) {
            guard !unique.contains(where: { $0.destination.coordinate.distance(to: candidate.destination.coordinate) < 15 }) else { continue }
            unique.append(candidate)
            if unique.count >= max(1, min(resultLimit, 100)) { break }
        }
        let namesByID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0.destination.name) })
        await OpenStreetMapPlaceDetailsProvider.cacheSearchDetails(decoded.elements.compactMap { element in
            guard let type = element.type, let tags = element.tags,
                  let name = namesByID["\(type)-\(element.id)"] else { return nil }
            return (id: "\(type):\(element.id)", name: name, tags: tags)
        })
        return unique
    }

    private static func fuelTypes(from tags: [String: String]) -> [String] {
        tags.compactMap { entry -> String? in
            let (key, value) = entry
            guard key.hasPrefix("fuel:"), value.lowercased() != "no" else { return nil }
            return String(key.dropFirst("fuel:".count))
        }.sorted()
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
