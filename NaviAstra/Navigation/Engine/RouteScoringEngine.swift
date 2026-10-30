import Foundation

nonisolated enum RoutePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case fastest, balanced, shortest, comfortable, personalized
    var id: Self { self }
    var title: String {
        switch self {
        case .fastest: "Najszybsza"
        case .balanced: "Zrównoważona"
        case .shortest: "Najkrótsza"
        case .comfortable: "Wygodna"
        case .personalized: "Polecana dla mnie"
        }
    }
}

/// Costs are ranking heuristics, never additions to the displayed ETA.
/// Missing provider data stays unknown rather than becoming a good score.
nonisolated struct RouteScore: Codable, Sendable {
    let travelTime: Double
    let distance: Double
    let trafficDelay: Double?
    let maneuverCost: Double
    let roadQualityCost: Double?
    let reliabilityCost: Double? // Lack of measured traffic coverage, not a statistical failure probability.
    let tollCost: Double? // No tariff feed; do not invent a monetary cost.
    var hasManeuverData = true
}

nonisolated enum RouteScoringEngine {
    static func score(_ route: NavigationRoute, from distance: Double = 0,
                      traffic: TrafficSnapshot? = nil) -> RouteScore {
        let geometry = RouteProgressGeometry(route)
        let start = max(0, min(geometry.length, distance))
        let base = RoadRouteETA.estimate(route, prepared: .init(route, geometry: geometry),
                                        from: start, traffic: nil)
        let eta = traffic.map {
            RoadRouteETA.estimate(route, prepared: .init(route, geometry: geometry), from: start, traffic: $0)
        } ?? base
        let remaining = route.maneuvers.filter {
            geometry.cumulativeDistances.indices.contains($0.shapeIndex) &&
                geometry.cumulativeDistances[$0.shapeIndex] >= start
        }
        let roughDataKnown = !remaining.isEmpty && remaining.allSatisfy {
            guard let information = $0.information, let rough = information.rough else { return false }
            return !rough || (information.distanceMeters.map { $0.isFinite && $0 >= 0 } ?? false)
        }
        let roughMeters = remaining.reduce(0.0) { total, turn in
            guard turn.information?.rough == true else { return total }
            let begin = geometry.cumulativeDistances[turn.shapeIndex]
            return total + min(max(0, geometry.length - max(start, begin)),
                               max(0, turn.information?.distanceMeters ?? 0))
        }
        let trafficKnown = traffic.map { Date().timeIntervalSince($0.updatedAt) <= 240 &&
            ($0.routeFlowSegments.contains { $0.routeID == route.id } || ($0.incidentDataAvailable && Date().timeIntervalSince($0.updatedAt) <= 120)) } ?? false
        return RouteScore(travelTime: eta,
            distance: route.distance * (geometry.length > 0 ? (geometry.length - start) / geometry.length : 1),
            trafficDelay: trafficKnown ? max(0, eta - base) : nil,
            maneuverCost: remaining.reduce(0) { $0 + maneuverCost($1.kind) },
            roadQualityCost: roughDataKnown ? roughMeters / 1_000 * 30 : nil,
            reliabilityCost: RouteReliability.evaluate(route: route, from: start, traffic: traffic).trafficEvidence.map { 1 - $0 }, tollCost: nil, hasManeuverData: !route.maneuvers.isEmpty)
    }

    static func maneuverCost(_ kind: ManeuverKind) -> Double {
        switch kind {
        case .uTurnLeft, .uTurnRight: 45
        case .sharpLeft, .sharpRight: 18
        case .left, .right, .roundaboutEnter: 8
        case .slightLeft, .slightRight, .rampLeft, .rampRight, .exitLeft, .exitRight,
             .stayLeft, .stayRight, .merge: 4
        default: 0
        }
    }

    /// Ranking costs use seconds and metres with fixed conversion factors. One
    /// ordinary turn cannot acquire a large weight just because it is the only
    /// difference between two candidates. These costs never change the ETA.
    static func value(_ score: RouteScore, preference: RoutePreference,
                      includeRoadQuality: Bool = true, includeManeuvers: Bool = true,
                      includeReliability: Bool = true) -> Double {
        guard isValid(score) else { return .infinity }
        let comfort = (includeManeuvers ? score.maneuverCost : 0)
            + (includeRoadQuality ? score.roadQualityCost ?? 0 : 0)
        let uncertainty = includeReliability ? min(1, max(0, score.reliabilityCost ?? 0)) : 0
        switch preference {
        case .fastest: return score.travelTime
        case .shortest: return score.distance
        case .balanced, .personalized:
            return score.travelTime + score.distance * 0.01 + comfort + uncertainty * 60
        case .comfortable:
            return score.travelTime + score.distance * 0.01 + comfort * 2 + uncertainty * 90
        }
    }

    private static func isValid(_ score: RouteScore) -> Bool {
        score.travelTime.isFinite && score.travelTime >= 0 && score.distance.isFinite && score.distance >= 0
            && score.maneuverCost.isFinite && score.maneuverCost >= 0
    }

    struct DetourLimit: Sendable {
        let timeFraction: Double
        let maximumExtraTime: TimeInterval
        let distanceFraction: Double
        let maximumExtraDistance: Double
    }

    static func detourLimit(for preference: RoutePreference) -> DetourLimit? {
        switch preference {
        case .balanced, .personalized:
            return DetourLimit(timeFraction: 0.15, maximumExtraTime: 300,
                               distanceFraction: 0.20, maximumExtraDistance: 5_000)
        case .comfortable:
            return DetourLimit(timeFraction: 0.25, maximumExtraTime: 600,
                               distanceFraction: 0.30, maximumExtraDistance: 10_000)
        case .fastest, .shortest: return nil
        }
    }

    /// Limits affect the recommendation, not the availability of alternatives.
    /// Compare against one real fastest route, never a mixture of the fastest
    /// time and the distance of an unrelated shortest route.
    static func recommendationEligibility(_ scores: [RouteScore], preference: RoutePreference) -> [Bool] {
        guard let limit = detourLimit(for: preference),
              let fastest = scores.filter(isValid).min(by: {
                  $0.travelTime == $1.travelTime ? $0.distance < $1.distance : $0.travelTime < $1.travelTime
              }) else { return scores.map(isValid) }
        let latest = fastest.travelTime + min(fastest.travelTime * limit.timeFraction, limit.maximumExtraTime)
        let longest = fastest.distance + min(fastest.distance * limit.distanceFraction, limit.maximumExtraDistance)
        return scores.map { isValid($0) && $0.travelTime <= latest + 0.001 && $0.distance <= longest + 0.001 }
    }

    struct NormalizedComponents: Codable, Sendable {
        let time: Double
        let distance: Double
        let comfort: Double?
        let surface: Double?
        let reliability: Double?
    }

    static func normalized(_ scores: [RouteScore]) -> [NormalizedComponents] {
        // Fixed scales are only for diagnostics. Ranking uses the calibrated
        // costs above, not these bounded presentation values.
        let maneuversKnown = scores.allSatisfy(\.hasManeuverData)
        let qualityKnown = scores.allSatisfy { $0.roadQualityCost != nil }
        let reliabilityKnown = scores.allSatisfy { $0.reliabilityCost != nil }
        func norm(_ value: Double, _ reference: Double) -> Double {
            guard value.isFinite else { return 1 }
            return max(0, value) / (max(0, value) + reference)
        }
        return scores.map {
            NormalizedComponents(time: norm($0.travelTime, 600), distance: norm($0.distance, 10_000),
                comfort: maneuversKnown ? norm($0.maneuverCost, 120) : nil,
                surface: qualityKnown ? norm($0.roadQualityCost ?? 0, 60) : nil,
                reliability: reliabilityKnown ? $0.reliabilityCost : nil)
        }
    }

    static func rankingValues(_ scores: [RouteScore], preference: RoutePreference) -> [Double] {
        let comparable = scores.filter(isValid)
        let maneuversKnown = comparable.allSatisfy(\.hasManeuverData)
        let qualityKnown = comparable.allSatisfy { $0.roadQualityCost != nil }
        let reliabilityKnown = comparable.allSatisfy { $0.reliabilityCost != nil }
        let eligible = recommendationEligibility(scores, preference: preference)
        return scores.indices.map { index in
            guard eligible[index] else { return .infinity }
            return value(scores[index], preference: preference, includeRoadQuality: qualityKnown,
                         includeManeuvers: maneuversKnown, includeReliability: reliabilityKnown)
        }
    }

    static func ranked(_ routes: [NavigationRoute], preference: RoutePreference,
                       from starts: [UUID: Double] = [:], traffic: [UUID: TrafficSnapshot] = [:]) -> [NavigationRoute] {
        let scores = routes.map { score($0, from: starts[$0.id] ?? 0, traffic: traffic[$0.id]) }
        let values = rankingValues(scores, preference: preference)
        return routes.indices.sorted { a, b in
            if values[a] != values[b] { return values[a] < values[b] }
            if scores[a].travelTime != scores[b].travelTime { return scores[a].travelTime < scores[b].travelTime }
            if scores[a].distance != scores[b].distance { return scores[a].distance < scores[b].distance }
            return a < b
        }.map { routes[$0] }
    }

}

/// Approximate directional overlap sampled every 50 m; not shared OSM edge IDs.
nonisolated enum RouteSimilarity {
    static func overlap(_ a: NavigationRoute, _ b: NavigationRoute) -> Double {
        let ga = RouteProgressGeometry(a), gb = RouteProgressGeometry(b)
        let source = ga.length <= gb.length ? ga : gb
        let target = ga.length <= gb.length ? gb : ga
        guard source.length > 0, target.length > 0 else { return 0 }
        // A bounded number of weighted cells keeps long-distance routes affordable.
        let count = min(4_000, max(1, Int(ceil(source.length / 50))))
        let step = source.length / Double(count)
        var shared = 0.0
        for index in 0..<count {
            let distance = (Double(index) + 0.5) * step
            guard let point = source.coordinate(at: distance),
                  let projection = target.project(point, within: 15), projection.distanceFromRoute <= 15,
                  let a1 = source.coordinate(at: max(0, distance - 5)),
                  let a2 = source.coordinate(at: min(source.length, distance + 5)),
                  let b1 = target.coordinate(at: max(0, projection.alongRoute - 5)),
                  let b2 = target.coordinate(at: min(target.length, projection.alongRoute + 5)),
                  RoadGeometryAlignment.isAligned(a1, a2, b1, b2, directed: true) else { continue }
            shared += step
        }
        return min(1, shared / source.length)
    }

    static func diverse(_ ranked: [NavigationRoute], maximumOverlap: Double = 0.8,
                        preserving preferredIDs: Set<UUID> = []) -> [NavigationRoute] {
        var result: [NavigationRoute] = []
        var preservedCount = 0
        var geometries: [UUID: RouteProgressGeometry] = [:]
        func geometry(_ route: NavigationRoute) -> RouteProgressGeometry {
            if let cached = geometries[route.id] { return cached }
            let value = RouteProgressGeometry(route)
            geometries[route.id] = value
            return value
        }
        for candidate in ranked {
            let isPreferred = preferredIDs.contains(candidate.id)
            if isPreferred, preservedCount >= 2 { continue }
            let duplicates = result.contains { selected in
                // Different EV charging itineraries remain meaningful even on the same road.
                guard selected.chargingStops.map(\.id) == candidate.chargingStops.map(\.id) else { return false }
                // A 200 m personal section remains meaningful on a 100 km route.
                // Do not discard it because its share of the whole trip is small.
                if isPreferred || preferredIDs.contains(selected.id) {
                    return strictCopies(geometry(selected), geometry(candidate))
                }
                return overlap(selected, candidate) >= maximumOverlap
            }
            if !duplicates {
                result.append(candidate)
                if isPreferred { preservedCount += 1 }
            }
        }
        return result
    }

    private static func strictCopies(_ first: RouteProgressGeometry, _ second: RouteProgressGeometry) -> Bool {
        if first.coordinates == second.coordinates { return true }
        guard first.length > 0, second.length > 0, abs(first.length - second.length) <= 20,
              let aStart = first.coordinates.first, let bStart = second.coordinates.first,
              let aEnd = first.coordinates.last, let bEnd = second.coordinates.last,
              aStart.distance(to: bStart) <= 15, aEnd.distance(to: bEnd) <= 15 else { return false }
        return followsEveryVertex(first, along: second) && followsEveryVertex(second, along: first)
    }

    /// Vertex checks cannot skip a short different section on a long journey.
    /// Geometry is cached and this stricter comparison is limited to two personal candidates.
    private static func followsEveryVertex(_ source: RouteProgressGeometry,
                                          along target: RouteProgressGeometry) -> Bool {
        for index in source.coordinates.indices {
            let distance = source.cumulativeDistances[index]
            guard let projection = target.project(source.coordinates[index], within: 15),
                  projection.distanceFromRoute <= 15,
                  let a = source.coordinate(at: max(0, distance - 5)),
                  let b = source.coordinate(at: min(source.length, distance + 5)),
                  let c = target.coordinate(at: max(0, projection.alongRoute - 5)),
                  let d = target.coordinate(at: min(target.length, projection.alongRoute + 5)),
                  RoadGeometryAlignment.isAligned(a, b, c, d, directed: true) else { return false }
        }
        return true
    }
}
