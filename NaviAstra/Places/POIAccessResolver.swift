import Foundation

nonisolated enum POINavigationTargetType: String, Sendable {
    case parking
    case parkingAccess
    case frontEntrance
    case nearestRoad
}

nonisolated struct POINavigationTarget: Equatable, Sendable {
    var coordinate: Coordinate
    var type: POINavigationTargetType
    var confidence: Double
}

/// Resolves a map/search POI to an OSM access point before routing.
actor POIAccessResolver {
    static let shared = POIAccessResolver()

    private struct CachedTarget {
        var value: POINavigationTarget
        var expiresAt: Date
    }

    private struct CachedFeatures {
        var values: [Feature]
        var expiresAt: Date
    }

    private var cache: [String: CachedTarget] = [:]
    private var featureCache: [String: CachedFeatures] = [:]
    private let endpoint = URL(string: UserDefaults.standard.string(forKey: "overpassServer")
                               ?? "https://overpass-api.de/api/interpreter")!

    func resolve(for destination: Destination, mode: TransportMode) async -> POINavigationTarget? {
        guard let poi = destination.poi else { return nil }
        let resolvedMode: TransportMode
        switch mode {
        case .car, .walking, .bicycle: resolvedMode = mode
        case .transit, .parkRide: resolvedMode = .walking
        }

        let key = cacheKey(destination, poi: poi, mode: resolvedMode)
        if let cached = cache[key], cached.expiresAt > Date() { return cached.value }
        let featuresKey = cacheKey(destination, poi: poi, mode: .walking)
        guard let features = await fetchFeatures(near: destination.coordinate, poi: poi,
                                                 cacheKey: featuresKey) else { return nil }
        let target = resolvedMode == .car
            ? carTarget(for: destination, poi: poi, features: features)
            : activeEntranceTarget(for: destination, poi: poi, mode: resolvedMode, features: features)
        if let target {
            cache[key] = CachedTarget(value: target, expiresAt: Date().addingTimeInterval(6 * 60 * 60))
        }
        return target
    }

    func resolveMany(for destinations: [Destination], mode: TransportMode,
                     maximumConcurrentRequests: Int = 3) async -> [POINavigationTarget?] {
        guard !destinations.isEmpty else { return [] }
        var resolved = Array<POINavigationTarget?>(repeating: nil, count: destinations.count)
        await withTaskGroup(of: (Int, POINavigationTarget?).self) { group in
            let limit = max(1, min(maximumConcurrentRequests, destinations.count))
            var nextIndex = 0
            while nextIndex < limit {
                let index = nextIndex
                group.addTask { [self] in
                    (index, await resolve(for: destinations[index], mode: mode))
                }
                nextIndex += 1
            }
            while let (index, target) = await group.next() {
                resolved[index] = target
                guard nextIndex < destinations.count else { continue }
                let next = nextIndex
                group.addTask { [self] in
                    (next, await resolve(for: destinations[next], mode: mode))
                }
                nextIndex += 1
            }
        }
        return resolved
    }

    private func cacheKey(_ destination: Destination, poi: POIMetadata, mode: TransportMode) -> String {
        let identity = OpenStreetMapObjectID(poi.osmID)?.cacheKey
            ?? "\(normalized(destination.name))/\(Int((destination.coordinate.latitude * 100_000).rounded()))/\(Int((destination.coordinate.longitude * 100_000).rounded()))"
        return "\(identity)/\(mode.rawValue)"
    }

    private func fetchFeatures(near center: Coordinate, poi: POIMetadata,
                               cacheKey: String) async -> [Feature]? {
        if let cached = featureCache[cacheKey], cached.expiresAt > Date() { return cached.values }
        let radius = 250
        var selectors: [String] = []
        if let objectID = OpenStreetMapObjectID(poi.osmID) {
            selectors.append("\(objectID.selector);")
        }
        let around = "around:\(radius),\(center.latitude),\(center.longitude)"
        selectors += [
            "nwr(\(around))[\"amenity\"=\"parking\"];",
            "nwr(\(around))[\"entrance\"=\"main\"];",
            "way(\(around))[\"highway\"];",
            "way(\(around))[\"service\"=\"parking_aisle\"];",
            "node(\(around))[\"highway\"=\"service\"];",
            "nwr(\(around))[\"name\"];"
        ]
        let query = "[out:json][timeout:7];(\(selectors.joined()))out center geom tags;"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 9
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra/1.0 (POI access resolver)", forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.remark == nil else {
                return nil
            }
            var unique: [String: Feature] = [:]
            for element in reply.elements {
                guard let type = element.type, let tags = element.tags else { continue }
                let feature = Feature(type: type, id: element.id, tags: tags,
                                      coordinate: element.coordinate,
                                      geometry: (element.geometry ?? []).compactMap(\.coordinate))
                unique["\(type):\(element.id)"] = feature
            }
            let features = unique.values.sorted {
                if $0.type != $1.type { return $0.type < $1.type }
                return $0.id < $1.id
            }
            featureCache[cacheKey] = CachedFeatures(values: features,
                                                    expiresAt: Date().addingTimeInterval(60 * 60))
            return features
        } catch {
            return nil
        }
    }

    private func activeEntranceTarget(for destination: Destination, poi: POIMetadata, mode: TransportMode,
                                      features: [Feature]) -> POINavigationTarget? {
        let place = matchPlace(destination, poi: poi, features: features)
        if let entrance = bestMainEntrance(for: destination, matchedPlace: place, features: features),
           let coordinate = entrance.coordinate {
            return POINavigationTarget(coordinate: coordinate, type: .frontEntrance, confidence: 0.95)
        }
        guard let road = nearestRoad(to: destination.coordinate, mode: mode, features: features),
              road.distance <= 80 else { return nil }
        return POINavigationTarget(coordinate: road.coordinate, type: .nearestRoad,
                                   confidence: max(0.25, 0.55 - road.distance / 300))
    }

    private func carTarget(for destination: Destination, poi: POIMetadata,
                           features: [Feature]) -> POINavigationTarget? {
        let matchedPlace = matchPlace(destination, poi: poi, features: features)
        let placeGeometry = matchedPlace?.polygon ?? []
        let placeCoordinate = matchedPlace?.coordinate ?? destination.coordinate
        let entrance = bestMainEntrance(for: destination, matchedPlace: matchedPlace,
                                        features: features)?.coordinate
        let parkingAreas = features.filter {
            $0.tags["amenity"] == "parking" && $0.geometry.count >= 3 && !isRestricted($0.tags)
        }

        var parkingChoices: [(Feature, Double, Double)] = []
        for parking in parkingAreas {
            let areaDistance = distance(from: placeCoordinate, to: parking.polygon)
            guard areaDistance <= 250 else { continue }
            let buildingGap = placeGeometry.isEmpty ? areaDistance : polygonGap(placeGeometry, parking.polygon)
            let entranceGap = entrance.map { distance(from: $0, to: parking.polygon) } ?? .infinity
            let score = parkingAssociationScore(parking, placeCoordinate: placeCoordinate,
                                                buildingGap: buildingGap, entranceGap: entranceGap,
                                                poi: poi, destination: destination)
            guard score >= 75 else { continue }
            parkingChoices.append((parking, score, min(buildingGap, entranceGap)))
        }
        parkingChoices.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.0.type != $1.0.type { return $0.0.type < $1.0.type }
            return $0.0.id < $1.0.id
        }

        var parkingAreaFallback: POINavigationTarget?
        for (parking, associationScore, _) in parkingChoices {
            let reference = entrance ?? placeCoordinate
            let accessRoads = serviceRoadPoints(in: parking.polygon, features: features)
                .filter { !$0.deliveryArea && $0.coordinate.distance(to: reference) >= 10 }
            if let access = accessRoads.min(by: {
                $0.coordinate.distance(to: reference) + $0.selectionPenalty
                    < $1.coordinate.distance(to: reference) + $1.selectionPenalty
            }) {
                let roadScore: Double = access.parkingAisle ? 1 : 0.86
                let confidence = min(0.98, max(0.55, associationScore / 300 * roadScore))
                return POINavigationTarget(coordinate: access.coordinate, type: .parkingAccess,
                                           confidence: confidence)
            }
            if let parkingPoint = representativePoint(in: parking.polygon, offsetFrom: reference) {
                if parkingAreaFallback == nil {
                    parkingAreaFallback = POINavigationTarget(
                        coordinate: parkingPoint, type: .parking,
                        confidence: min(0.72, max(0.4, associationScore / 360)))
                }
            }
        }
        if let parkingAreaFallback { return parkingAreaFallback }

        let roadReference = entrance ?? placeCoordinate
        guard let road = nearestRoad(to: roadReference, mode: .car, features: features), road.distance <= 100 else {
            return nil
        }
        return POINavigationTarget(coordinate: road.coordinate, type: .nearestRoad,
                                   confidence: max(0.2, 0.48 - road.distance / 400))
    }

    private func matchPlace(_ destination: Destination, poi: POIMetadata,
                            features: [Feature]) -> Feature? {
        if let objectID = OpenStreetMapObjectID(poi.osmID),
           let exact = features.first(where: { $0.type == objectID.type && $0.id == objectID.value }) {
            return exact
        }
        return features.compactMap { feature -> (Feature, Double)? in
            guard feature.coordinate != nil, feature.coordinate!.distance(to: destination.coordinate) <= 80,
                  hasMatchingIdentity(feature.tags, destination: destination, poi: poi) else { return nil }
            let matchesExpectedCategory = poi.category.map { categoryMatches($0, tags: feature.tags) } ?? false
            let score = (matchesExpectedCategory ? 100.0 : 0)
                - feature.coordinate!.distance(to: destination.coordinate)
            return (feature, score)
        }.max { $0.1 < $1.1 }?.0
    }

    private func bestMainEntrance(for destination: Destination, features: [Feature]) -> Feature? {
        bestMainEntrance(for: destination, matchedPlace: nil, features: features)
    }

    private func bestMainEntrance(for destination: Destination, matchedPlace: Feature?,
                                  features: [Feature]) -> Feature? {
        let polygon = matchedPlace?.polygon ?? []
        return features.filter { $0.tags["entrance"] == "main" && $0.coordinate != nil }
            .compactMap { feature -> (Feature, Double)? in
                guard let coordinate = feature.coordinate else { return nil }
                let offset = polygon.isEmpty ? coordinate.distance(to: destination.coordinate)
                    : distance(from: coordinate, to: polygon)
                guard offset <= 70 else { return nil }
                return (feature, offset)
            }
            .min { $0.1 < $1.1 }?.0
    }

    private func parkingAssociationScore(_ parking: Feature, placeCoordinate: Coordinate,
                                         buildingGap: Double, entranceGap: Double,
                                         poi: POIMetadata, destination: Destination) -> Double {
        var score = 0.0
        if hasMatchingIdentity(parking.tags, destination: destination, poi: poi) { score += 100 }
        if buildingGap <= 12 { score += 85 }
        else if buildingGap <= 30 { score += 60 }
        else if buildingGap <= 60 { score += 30 }
        if entranceGap < 20 { score += 55 }
        else if entranceGap < 50 { score += 35 }
        else if entranceGap < 90 { score += 10 }
        if parking.tags["access"] == "customers" { score += 15 }
        if let parkingCenter = parking.coordinate {
            let distance = parkingCenter.distance(to: placeCoordinate)
            if distance < 80 { score += 15 }
            else if distance < 150 { score += 7 }
        }
        return score
    }

    private struct RoadPoint {
        var coordinate: Coordinate
        var parkingAisle: Bool
        var deliveryArea: Bool
        var selectionPenalty: Double
    }

    private func serviceRoadPoints(in polygon: [Coordinate], features: [Feature]) -> [RoadPoint] {
        features.filter { isServiceRoad($0.tags) }.flatMap { feature -> [RoadPoint] in
            guard !isRestricted(feature.tags) else { return [] }
            let path = feature.geometry.isEmpty ? [feature.coordinate].compactMap { $0 } : feature.geometry
            guard !path.isEmpty else { return [] }
            var points: [Coordinate] = []
            if path.count == 1 {
                points = path
            } else {
                for index in 1..<path.count {
                    let start = path[index - 1]
                    let end = path[index]
                    let segmentLength = start.distance(to: end)
                    let steps = max(1, min(60, Int(ceil(segmentLength / 10))))
                    for step in 0...steps {
                        points.append(interpolate(start, end, fraction: Double(step) / Double(steps)))
                    }
                }
            }
            let inArea = points.filter { distance(from: $0, to: polygon) <= 3 }
            let delivery = isDeliveryRoad(feature.tags)
            let selectionPenalty: Double
            if feature.tags["service"] == "parking_aisle" {
                selectionPenalty = 0
            } else if feature.tags["service"] == "driveway" {
                selectionPenalty = feature.tags["access"] == "customers" ? 8 : 35
            } else {
                selectionPenalty = 15
            }
            return inArea.map {
                RoadPoint(coordinate: $0, parkingAisle: feature.tags["service"] == "parking_aisle",
                          deliveryArea: delivery, selectionPenalty: selectionPenalty)
            }
        }
    }

    private func nearestRoad(to coordinate: Coordinate, mode: TransportMode,
                             features: [Feature]) -> (coordinate: Coordinate, distance: Double)? {
        features.filter { isNavigableRoad($0.tags, mode: mode) }
            .flatMap { feature -> [(Coordinate, Double, Double)] in
                let path = feature.geometry.isEmpty ? [feature.coordinate].compactMap { $0 } : feature.geometry
                guard !path.isEmpty else { return [] }
                let points: [Coordinate]
                if path.count == 1 {
                    points = path
                } else {
                    points = (1..<path.count).map {
                        closestPoint(to: coordinate, on: path[$0 - 1], and: path[$0])
                    }
                }
                let distancePenalty: Double = switch feature.tags["highway"] {
                case "service": 0
                case "residential", "unclassified", "living_street": 5
                case "tertiary", "tertiary_link": 12
                case "secondary", "secondary_link": 22
                case "primary", "primary_link": 35
                default: 18
                }
                return points.map { point in
                    let distance = point.distance(to: coordinate)
                    return (point, distance, distance + distancePenalty)
                }
            }
            .filter { $0.1 <= 250 }
            .min { $0.2 < $1.2 }
            .map { (coordinate: $0.0, distance: $0.1) }
    }

    private func isServiceRoad(_ tags: [String: String]) -> Bool {
        tags["highway"] == "service" || tags["service"] == "parking_aisle"
    }

    private func isNavigableRoad(_ tags: [String: String], mode: TransportMode) -> Bool {
        guard !isRestricted(tags), !isDeliveryRoad(tags),
              let highway = tags["highway"] else { return false }
        let motorRoads: Set<String> = ["service", "residential", "unclassified", "living_street", "road",
                                       "tertiary", "tertiary_link", "secondary", "secondary_link",
                                       "primary", "primary_link"]
        switch mode {
        case .car:
            return motorRoads.contains(highway)
        case .walking:
            if ["no", "private"].contains(tags["foot"] ?? "") { return false }
            return motorRoads.contains(highway)
                || ["footway", "path", "pedestrian", "steps"].contains(highway)
        case .bicycle:
            if ["no", "private"].contains(tags["bicycle"] ?? "") { return false }
            return motorRoads.contains(highway)
                || ["cycleway", "path"].contains(highway)
                || (highway == "footway" && ["yes", "designated"].contains(tags["bicycle"] ?? ""))
        case .transit, .parkRide:
            return false
        }
    }

    private func isRestricted(_ tags: [String: String]) -> Bool {
        ["access", "motor_vehicle"].contains { key in
            ["private", "no"].contains(tags[key] ?? "")
        }
    }

    private func isDeliveryRoad(_ tags: [String: String]) -> Bool {
        tags["delivery"] == "only" || tags["access"] == "delivery"
            || ["loading", "loading_area", "delivery"].contains(tags["service"] ?? "")
    }

    private func hasMatchingIdentity(_ tags: [String: String], destination: Destination,
                                     poi: POIMetadata) -> Bool {
        let expected = [poi.brand, poi.operatorName, destination.name]
            .compactMap { $0 }.map(normalized).filter { $0.count >= 4 }
        let actual = [tags["name"], tags["brand"], tags["operator"]]
            .compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
        return expected.contains { value in
            actual.contains { tagged in tagged == value || (tagged.count >= 4 && value.count >= 4 &&
                (tagged.contains(value) || value.contains(tagged))) }
        }
    }

    private func categoryMatches(_ expected: String, tags: [String: String]) -> Bool {
        let category = normalized(expected)
        return tags.values.contains { normalized($0) == category }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private func distance(from point: Coordinate, to polygon: [Coordinate]) -> Double {
        guard polygon.count >= 3 else {
            return polygon.map { point.distance(to: $0) }.min() ?? .infinity
        }
        if contains(point, polygon: polygon) { return 0 }
        return zip(polygon, Array(polygon.dropFirst()) + [polygon[0]]).map { pair in
            point.distance(to: closestPoint(to: point, on: pair.0, and: pair.1))
        }.min() ?? .infinity
    }

    private func polygonGap(_ lhs: [Coordinate], _ rhs: [Coordinate]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return .infinity }
        if lhs.contains(where: { contains($0, polygon: rhs) }) || rhs.contains(where: { contains($0, polygon: lhs) }) {
            return 0
        }
        return min(lhs.map { distance(from: $0, to: rhs) }.min() ?? .infinity,
                   rhs.map { distance(from: $0, to: lhs) }.min() ?? .infinity)
    }

    private func representativePoint(in polygon: [Coordinate], offsetFrom reference: Coordinate) -> Coordinate? {
        guard polygon.count >= 3 else { return nil }
        var vertices = polygon
        if let first = vertices.first, let last = vertices.last, first.distance(to: last) < 1 {
            vertices.removeLast()
        }
        guard !vertices.isEmpty else { return nil }
        let center = Coordinate(latitude: vertices.map(\.latitude).reduce(0, +) / Double(vertices.count),
                                longitude: vertices.map(\.longitude).reduce(0, +) / Double(vertices.count))
        if contains(center, polygon: polygon), center.distance(to: reference) >= 15 { return center }
        return vertices.filter { $0.distance(to: reference) >= 15 }
            .min { $0.distance(to: reference) < $1.distance(to: reference) }
    }

    private func contains(_ point: Coordinate, polygon: [Coordinate]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * cos(point.latitude * .pi / 180)
        let vertices = polygon.map {
            (x: ($0.longitude - point.longitude) * longitudeScale,
             y: ($0.latitude - point.latitude) * latitudeScale)
        }
        var inside = false
        var previous = vertices.count - 1
        for index in vertices.indices {
            let current = vertices[index]
            let prior = vertices[previous]
            if (current.y > 0) != (prior.y > 0),
               0 < (prior.x - current.x) * (0 - current.y) / (prior.y - current.y) + current.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    private func closestPoint(to point: Coordinate, on start: Coordinate, and end: Coordinate) -> Coordinate {
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * longitudeScale
        let ay = (start.latitude - point.latitude) * latitudeScale
        let bx = (end.longitude - point.longitude) * longitudeScale
        let by = (end.latitude - point.latitude) * latitudeScale
        let dx = bx - ax, dy = by - ay
        let denominator = dx * dx + dy * dy
        let fraction = denominator > 0 ? max(0, min(1, -(ax * dx + ay * dy) / denominator)) : 0
        return interpolate(start, end, fraction: fraction)
    }

    private func interpolate(_ start: Coordinate, _ end: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                   longitude: start.longitude + (end.longitude - start.longitude) * fraction)
    }

    private struct Reply: Decodable {
        var elements: [Element]
        var remark: String?
    }

    private struct Element: Decodable {
        var type: String?
        var id: Int64
        var lat: Double?
        var lon: Double?
        var center: Center?
        var geometry: [Geometry]?
        var tags: [String: String]?

        var coordinate: Coordinate? {
            if let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon) {
                return Coordinate(latitude: lat, longitude: lon)
            }
            return center?.coordinate ?? geometry?.first?.coordinate
        }
    }

    private struct Center: Decodable {
        var lat: Double
        var lon: Double
        var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    private struct Geometry: Decodable {
        var lat: Double
        var lon: Double
        var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    private struct Feature {
        var type: String
        var id: Int64
        var tags: [String: String]
        var coordinate: Coordinate?
        var geometry: [Coordinate]
        var polygon: [Coordinate] {
            guard geometry.count >= 3, let first = geometry.first, let last = geometry.last,
                  first.distance(to: last) < 8 else { return [] }
            return geometry
        }
    }
}
