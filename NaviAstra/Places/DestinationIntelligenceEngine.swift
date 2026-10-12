import Foundation

nonisolated enum POIAccessPurpose: String, Sendable { case arrival, departure }

nonisolated struct POIAccessApproach: Sendable {
    let origin: Coordinate
    var bearing: Double? = nil
}

nonisolated struct DestinationAccessFeature: Sendable {
    let id: String
    let coordinate: Coordinate?
    let geometry: [Coordinate]
    let tags: [String: String]
}

nonisolated struct DestinationAccessCandidate: Sendable {
    let coordinate: Coordinate
    let featureID: String
    let tags: [String: String]
    let inboundBearing: Double?
    let explicitEntrance: Bool
    let directionVerified: Bool
    let reasons: [String]
}

nonisolated enum DestinationIntelligenceEngine {
    static func motorAccessAllowed(_ tags: [String: String]) -> Bool {
        // Vehicle-specific access overrides the generic tag; conditional access is not invented.
        let access = tags["motorcar"] ?? tags["motor_vehicle"] ?? tags["vehicle"] ?? tags["access"]
        if ["no", "private", "delivery"].contains(access ?? "") { return false }
        if ["wall", "fence", "block", "bollard", "bus_trap"].contains(tags["barrier"] ?? "") {
            return ["yes", "permissive", "customers", "destination"].contains(access ?? "")
        }
        return true
    }

    static func candidates(parking: [Coordinate], features: [DestinationAccessFeature],
                           purpose: POIAccessPurpose = .arrival) -> [DestinationAccessCandidate] {
        guard parking.count >= 3 else { return [] }
        let barriers = features.filter { $0.tags["barrier"] != nil && !motorAccessAllowed($0.tags) }
        var result: [DestinationAccessCandidate] = []
        for feature in features where motorAccessAllowed(feature.tags) {
            if purpose == .arrival && (feature.tags["entrance"] == "exit" || feature.tags["parking_entrance"] == "exit") { continue }
            let path = feature.geometry
            let explicit = feature.tags["amenity"] == "parking_entrance" ||
                (feature.tags["entrance"] != nil && ["yes", "customers", "destination"].contains(
                    feature.tags["motor_vehicle"] ?? feature.tags["vehicle"] ?? ""))
            if explicit, let point = feature.coordinate,
               parking.map({ $0.distance(to: point) }).min() ?? .infinity <= 100 {
                guard !barriers.contains(where: { $0.coordinate.map { $0.distance(to: point) <= 3 } == true }) else { continue }
                result.append(DestinationAccessCandidate(coordinate: point, featureID: feature.id, tags: feature.tags,
                    inboundBearing: nil, explicitEntrance: true, directionVerified: false,
                    reasons: ["Oznaczony wjazd parkingowy; kierunek niepotwierdzony"]))
            }
            guard feature.tags["highway"] == "service", path.count >= 2,
                  !roadIsBlocked(feature, by: barriers) else { continue }
            for (a, b) in zip(path, path.dropFirst()) {
                let length = a.distance(to: b)
                guard length > 0 else { continue }
                let steps = max(2, min(100, Int(ceil(length / 5))))
                var before = a, insideBefore = contains(a, polygon: parking)
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    let current = Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                             longitude: a.longitude + (b.longitude - a.longitude) * fraction)
                    let inside = contains(current, polygon: parking)
                    defer { before = current; insideBefore = inside }
                    guard inside != insideBefore else { continue }
                    let forwardInbound = !insideBefore && inside
                    let forwardTravel = purpose == .arrival ? forwardInbound : !forwardInbound
                    let oneway = feature.tags["oneway"]?.lowercased()
                    if ["yes", "1", "true"].contains(oneway ?? "") && !forwardTravel { continue }
                    if oneway == "-1" && forwardTravel { continue }
                    let point = inside ? current : before
                    guard !barriers.contains(where: { $0.coordinate.map { $0.distance(to: point) <= 3 } == true }) else { continue }
                    let from = forwardTravel ? before : current, to = forwardTravel ? current : before
                    let dx = (to.longitude - from.longitude) * cos(point.latitude * .pi / 180)
                    let dy = to.latitude - from.latitude
                    let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                    if !result.contains(where: { $0.featureID == feature.id && $0.coordinate.distance(to: point) < 10 }) {
                        result.append(DestinationAccessCandidate(coordinate: point, featureID: feature.id, tags: feature.tags,
                            inboundBearing: bearing, explicitEntrance: false, directionVerified: true,
                            reasons: ["Droga serwisowa przecina granicę parkingu", oneway == nil ? "Kierunek z geometrii dojazdu" : "Sprawdzona jednokierunkowość"]))
                    }
                }
            }
        }
        return result
    }

    static func roadIsBlocked(_ road: DestinationAccessFeature, by features: [DestinationAccessFeature]) -> Bool {
        features.contains { feature in
            guard feature.tags["barrier"] != nil, !motorAccessAllowed(feature.tags), let coordinate = feature.coordinate else { return false }
            return MapMatcher.project(coordinate, onto: road.geometry)?.distanceFromRoute ?? .infinity <= 3
        }
    }

    static func best(_ candidates: [DestinationAccessCandidate], reference: Coordinate,
                     approach: POIAccessApproach?) -> DestinationAccessCandidate? {
        candidates.filter { motorAccessAllowed($0.tags) }.min { a, b in
            func cost(_ candidate: DestinationAccessCandidate) -> Double {
                var cost = candidate.coordinate.distance(to: reference)
                if candidate.explicitEntrance { cost -= 30 }
                if candidate.directionVerified { cost -= 20 }
                if let approach {
                    cost += min(500, approach.origin.distance(to: candidate.coordinate)) * 0.15
                    if let heading = approach.bearing, heading.isFinite, (0..<360).contains(heading), let inbound = candidate.inboundBearing {
                        let diff = abs(heading - inbound)
                        cost += min(diff, 360 - diff) / 180 * 35
                    }
                }
                return cost
            }
            let left = cost(a), right = cost(b)
            return left == right ? a.featureID < b.featureID : left < right
        }
    }

    private static func contains(_ point: Coordinate, polygon: [Coordinate]) -> Bool {
        var inside = false, previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index], b = polygon[previous]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) /
                    (b.latitude - a.latitude) + a.longitude { inside.toggle() }
            previous = index
        }
        return inside
    }
}
