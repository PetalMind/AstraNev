import Foundation

nonisolated struct RoadExclusionConflict: LocalizedError {
    let routes: [NavigationRoute]
    var errorDescription: String? {
        "Nie znaleziono przejezdnej trasy, która omija wszystkie zamknięcia i wykluczone obszary."
    }
}

/// A reduced request can guide the search, but it never reduces the evidence used to accept a route.
struct RoadPlanExclusions {
    let closures: [RoadExclusionPolygon]
    let congestion: [RoadExclusionPolygon]
    let manual: [RoadExclusionPolygon]
    static let maximumAutomaticRings = 256
    // A few short barriers steer the search even when one original road alone exceeds the server budget.
    private static let maximumProbeBarriers = 8

    init(closures known: [String: ConfirmedRoadClosure], manualAreas: [ValhallaAvoidArea]) throws {
        var unique = Set<[[Double]]>()
        var closures: [RoadExclusionPolygon] = []
        for ring in RoadRoutingContext.closurePolygons where unique.insert(ring).inserted {
            closures.append(try RoadExclusionPolygon(ring: ring))
        }
        for closure in known.values.sorted(by: { $0.id < $1.id }) {
            let avoidance = try closure.avoidance()
            closures.append(contentsOf: avoidance.exclusions.filter { unique.insert($0.ring).inserted })
        }
        self.closures = closures
        congestion = try RoadRoutingContext.congestionAvoidancePolygons.compactMap {
            guard unique.insert($0).inserted else { return nil }
            return try RoadExclusionPolygon(ring: $0)
        }
        manual = try ValhallaAvoidArea.validatedRings(manualAreas).map { try RoadExclusionPolygon(ring: $0) }
    }

    func calculate(_ plan: () async throws -> [NavigationRoute]) async throws -> [NavigationRoute] {
        let automatic = closures + congestion
        return try await RoadRoutingContext.$routeExclusions.withValue(manual + automatic) {
            if automatic.count <= Self.maximumAutomaticRings {
                do {
                    return try await attempt(closures: closures, congestion: congestion, plan: plan)
                } catch let error as ValhallaServerError where error.exceedsPolygonPerimeter && !automatic.isEmpty {
                    try RoadRoutingContext.checkCancellation()
                }
            }
            return try await RoadRoutingContext.$recoveringPolygonLimit.withValue(true) {
                do {
                    // The probe keeps the user's areas, options and itinerary. It may itself be a safe detour.
                    return try await attempt(closures: [], congestion: [], plan: plan)
                } catch let conflict as RoadExclusionConflict {
                    guard let probe = conflict.routes.first else { throw conflict }
                    let focused = try focusedExclusions(on: probe, automatic: automatic)
                    guard !focused.isEmpty else { throw conflict }
                    do {
                        return try await attempt(closures: focused, congestion: [], plan: plan)
                    } catch let error as ValhallaServerError where error.exceedsPolygonPerimeter {
                        throw conflict
                    }
                } catch let error as ValhallaServerError where error.exceedsPolygonPerimeter && manual.isEmpty {
                    throw RoadExclusionConflict(routes: [])
                }
            }
        }
    }

    private func attempt(closures: [RoadExclusionPolygon], congestion: [RoadExclusionPolygon],
                         plan: () async throws -> [NavigationRoute]) async throws -> [NavigationRoute] {
        try RoadRoutingContext.checkCancellation()
        return try await RoadRoutingContext.$closurePolygons.withValue(closures.map(\.ring)) {
            try await RoadRoutingContext.$congestionAvoidancePolygons.withValue(congestion.map(\.ring)) {
                let routes = try await plan()
                return try RoadRoutingContext.routesAvoidingExclusions(routes)
            }
        }
    }

    private func focusedExclusions(on probe: NavigationRoute, automatic: [RoadExclusionPolygon]) throws -> [RoadExclusionPolygon] {
        let barriers = automatic.lazy.compactMap { $0.localizedBarrier(on: probe) }.prefix(Self.maximumProbeBarriers)
        return try barriers.map { try RoadExclusionPolygon(ring: $0) }
    }
}
