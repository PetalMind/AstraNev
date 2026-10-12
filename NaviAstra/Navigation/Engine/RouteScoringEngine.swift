import Foundation

nonisolated enum RoutePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case fastest, balanced, shortest, comfortable
    var id: Self { self }
    var title: String {
        switch self {
        case .fastest: "Najszybsza"
        case .balanced: "Zrównoważona"
        case .shortest: "Najkrótsza"
        case .comfortable: "Wygodna"
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

    static func value(_ score: RouteScore, preference: RoutePreference,
                      includeRoadQuality: Bool = true) -> Double {
        guard score.travelTime.isFinite, score.distance.isFinite else { return .infinity }
        let comfort = score.maneuverCost + (includeRoadQuality ? score.roadQualityCost ?? 0 : 0)
        switch preference {
        case .fastest: return score.travelTime
        case .shortest: return score.distance
        case .balanced: return score.travelTime + comfort
        case .comfortable: return score.travelTime + comfort * 2
        }
    }

    struct NormalizedComponents: Codable, Sendable {
        let time: Double
        let distance: Double
        let comfort: Double?
        let surface: Double?
        let reliability: Double?
    }

    static func normalized(_ scores: [RouteScore]) -> [NormalizedComponents] {
        func scale(_ values: [Double]) -> Double {
            let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
            guard !sorted.isEmpty else { return 1 }
            return sorted[sorted.count / 2]
        }
        let timeScale = scale(scores.map(\.travelTime)), distanceScale = scale(scores.map(\.distance))
        let comfortScale = scale(scores.map(\.maneuverCost))
        let maneuversKnown = scores.allSatisfy(\.hasManeuverData)
        let qualityKnown = scores.allSatisfy { $0.roadQualityCost != nil }
        let reliabilityKnown = scores.allSatisfy { $0.reliabilityCost != nil }
        let surfaceScale = scale(scores.compactMap(\.roadQualityCost))
        func norm(_ value: Double, _ reference: Double) -> Double {
            guard value.isFinite else { return 1 }
            return max(0, value) / (max(0, value) + reference)
        }
        return scores.map {
            NormalizedComponents(time: norm($0.travelTime, timeScale), distance: norm($0.distance, distanceScale),
                comfort: maneuversKnown ? norm($0.maneuverCost, comfortScale) : nil,
                surface: qualityKnown ? norm($0.roadQualityCost ?? 0, surfaceScale) : nil,
                reliability: reliabilityKnown ? $0.reliabilityCost : nil)
        }
    }

    static func normalizedValue(_ components: NormalizedComponents, preference: RoutePreference) -> Double {
        let comfortWeight = preference == .comfortable ? 0.45 : 0.20
        let timeWeight = preference == .comfortable ? 0.30 : 0.55
        var sum = components.time * timeWeight + components.distance * 0.10
        var weight = timeWeight + 0.10
        if let comfort = components.comfort { sum += comfort * comfortWeight; weight += comfortWeight }
        if let surface = components.surface { sum += surface * 0.05; weight += 0.05 }
        if let reliability = components.reliability { sum += reliability * 0.10; weight += 0.10 }
        return sum / weight
    }

    static func rankingValues(_ scores: [RouteScore], preference: RoutePreference) -> [Double] {
        if preference == .balanced || preference == .comfortable {
            return normalized(scores).enumerated().map { index, components in
                scores[index].travelTime.isFinite && scores[index].distance.isFinite ? normalizedValue(components, preference: preference) : .infinity
            }
        }
        return scores.map { value($0, preference: preference) }
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

    static func diverse(_ ranked: [NavigationRoute], maximumOverlap: Double = 0.8) -> [NavigationRoute] {
        var result: [NavigationRoute] = []
        for candidate in ranked {
            let duplicates = result.contains { selected in
                // Different EV charging itineraries remain meaningful even on the same road.
                guard selected.chargingStops.map(\.id) == candidate.chargingStops.map(\.id) else { return false }
                return overlap(selected, candidate) >= maximumOverlap
            }
            if !duplicates { result.append(candidate) }
        }
        return result
    }
}
