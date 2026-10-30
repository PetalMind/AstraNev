import Foundation

/// The same fresh, geometrically usable closure evidence drives ETA and detours.
nonisolated struct ConfirmedRoadClosure: Sendable {
    let incident: TrafficIncident
    let observedAt: Date
    let maximumAge: TimeInterval
    var id: String { incident.id }
    var geometry: [Coordinate] { incident.geometry }

    func isFresh(at now: Date = .now) -> Bool {
        (-5...maximumAge).contains(now.timeIntervalSince(observedAt)) && incident.isActive(at: now)
    }

    func avoidance() throws -> RoadClosureAvoidance {
        try RoadClosureAvoidance(geometry: geometry)
    }

    func distanceAhead(on route: NavigationRoute, after start: Double, through end: Double,
                       now: Date = .now) -> Double? {
        guard isFresh(at: now) else { return nil }
        let routeGeometry = RouteProgressGeometry(route)
        guard let projection = RouteTrafficMonitor.incidentProjection(incident, geometry: routeGeometry,
                                                                       route: route, at: now) else { return nil }
        let upper = geometry.compactMap { point -> Double? in
            guard let match = routeGeometry.project(point), match.distanceFromRoute <= 20 else { return nil }
            return match.alongRoute
        }.max() ?? projection.alongRoute
        // A closure beginning behind the vehicle can still cover the road ahead.
        guard upper > start + 20, projection.alongRoute < end else { return nil }
        return max(start, projection.alongRoute)
    }

    static func evidence(in snapshot: TrafficSnapshot, route: NavigationRoute,
                         now: Date = .now) -> [Self] {
        var result: [Self] = snapshot.incidentDataAvailable ? snapshot.incidents.compactMap { incident in
            guard incident.isRoadClosure, incident.geometry.count >= 2 else { return nil }
            let closure = Self(incident: incident, observedAt: incident.observedAt ?? snapshot.updatedAt,
                               maximumAge: 120)
            return closure.isFresh(at: now) ? closure : nil
        } : []
        for segment in snapshot.routeFlowSegments where segment.routeID == route.id && segment.isRoadClosure {
            guard segment.coordinates.count >= 2 else { continue }
            let observedAt = segment.measuredAt ?? snapshot.updatedAt
            // Do not use route UUIDs: the evidence must survive replacement of the route.
            let key = segment.coordinates.map {
                "\(Int(($0.latitude * 100_000).rounded())),\(Int(($0.longitude * 100_000).rounded()))"
            }.joined(separator: ";")
            let incident = TrafficIncident(id: "flow-closure:\(key)", description: "Zamknięcie drogi",
                coordinate: segment.coordinates[0], delaySeconds: nil, category: .roadClosed,
                severity: .major, geometry: segment.coordinates, observedAt: observedAt)
            let closure = Self(incident: incident, observedAt: observedAt, maximumAge: 240)
            if closure.isFresh(at: now) { result.append(closure) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }
}

enum TrafficRouteEvaluationError: Error { case insufficientCoverage }

/// A temporary exclusion used only to request one alternative to measured congestion.
/// It never becomes closure evidence or changes road-availability messages.
nonisolated struct CongestionDetourCandidate {
    let area: RoadClosureAvoidance
    let measuredDelay: TimeInterval

    static func largest(on route: NavigationRoute, after start: Double, traffic: TrafficSnapshot,
                        mandatoryCoordinates: [Coordinate], now: Date = .now) -> Self? {
        let geometry = RouteProgressGeometry(route)
        return traffic.routeFlowSegments.compactMap { segment -> Self? in
            guard segment.routeID == route.id, !segment.isRoadClosure,
                  (-5...240).contains(now.timeIntervalSince(segment.measuredAt ?? traffic.updatedAt)),
                  let speed = segment.currentSpeedKph, speed.isFinite, speed >= 0,
                  let freeSpeed = segment.freeFlowSpeedKph, freeSpeed.isFinite, freeSpeed > 0,
                  speed <= freeSpeed * 0.5,
                  segment.startDistance >= start + 250, segment.endDistance <= geometry.length - 250,
                  segment.endDistance - segment.startDistance >= 100,
                  RouteTrafficMonitor.overlapProjection(segment.coordinates, geometry: geometry,
                                                       tolerance: 10) != nil,
                  !mandatoryCoordinates.contains(where: { coordinate in
                      (MapMatcher.project(coordinate, onto: segment.coordinates)?.distanceFromRoute ?? .infinity) <= 100
                  }), let area = try? RoadClosureAvoidance(geometry: segment.coordinates) else { return nil }
            let measured = (segment.endDistance - segment.startDistance) / (max(1, speed) / 3.6)
            let planned = RoadRouteETA.drivingTime(route, from: segment.startDistance, through: segment.endDistance)
            let delay = max(0, measured - planned)
            guard delay.isFinite, delay >= 60 else { return nil }
            return Self(area: area, measuredDelay: delay)
        }.max { $0.measuredDelay < $1.measuredDelay }
    }
}

/// Every candidate must have useful fresh observations before a comparison may change a route.
@MainActor
enum TrafficRouteEvaluator {
    static func snapshots(for routes: [NavigationRoute], starts: [UUID: Double] = [:],
                          provider: any TrafficProvider, isNavigating: Bool,
                          isForeground: Bool, wholeRoute: Bool = false,
                          requireComparableCoverage: Bool = true) async throws -> [UUID: TrafficSnapshot] {
        var snapshots: [UUID: TrafficSnapshot] = [:]
        for route in routes {
            try RoadRoutingContext.checkCancellation()
            let geometry = RouteProgressGeometry(route)
            let start = max(0, starts[route.id] ?? 0)
            let end = wholeRoute ? geometry.length : min(geometry.length,
                start + RouteTrafficMonitor.lookAheadDistance(for: route, progress: nil))
            let boxes = RouteTrafficMonitor.queryBoxes(for: route.coordinates, from: start, through: end)
            let queries = RouteTrafficMonitor.flowQueries(for: route, from: start, through: end,
                budget: TrafficSamplingBudget.resolved(isNavigating: isNavigating,
                    isForeground: isForeground, problemDetected: false))
            async let incidentRequest = provider.incidents(in: boxes)
            async let flowRequest = provider.routeFlowSamples(at: queries)
            let incidents = try await incidentRequest
            let samples = await flowRequest
            try RoadRoutingContext.checkCancellation()
            let enoughSamples = !queries.isEmpty &&
                samples.count >= max(1, Int(ceil(Double(queries.count) * 0.75)))
            let segments = RouteTrafficMonitor.coloredSegments(on: route, from: start, through: end,
                queries: queries, samples: samples, geometry: geometry)
            let traffic = TrafficSnapshot(flow: nil,
                incidents: RouteTrafficMonitor.matching(incidents, to: route, from: start,
                    through: end, routeGeometry: geometry), routeFlowSegments: segments,
                updatedAt: .now, partialError: enoughSamples ? nil : "Niepełne pomiary ruchu.",
                incidentDataAvailable: true)
            snapshots[route.id] = traffic
        }
        if requireComparableCoverage && !hasComparableCoverage(routes: routes, starts: starts,
                                                               traffic: snapshots, wholeRoute: wholeRoute) {
            throw TrafficRouteEvaluationError.insufficientCoverage
        }
        return snapshots
    }

    static func hasComparableCoverage(routes: [NavigationRoute], starts: [UUID: Double] = [:],
                                      traffic: [UUID: TrafficSnapshot], wholeRoute: Bool = false) -> Bool {
        guard !routes.isEmpty else { return false }
        let fractions = routes.compactMap { route -> Double? in
            guard let snapshot = traffic[route.id], snapshot.partialError == nil else { return nil }
            let start = starts[route.id] ?? 0
            let end = wholeRoute ? RouteProgressGeometry(route).length : start +
                RouteTrafficMonitor.lookAheadDistance(for: route, progress: nil)
            return TrafficCoverage.measure(route: route, from: start, through: end,
                                           traffic: snapshot).corridorFraction
        }
        guard fractions.count == routes.count, let minimum = fractions.min(), let maximum = fractions.max() else { return false }
        return minimum >= 0.5 && maximum - minimum <= 0.1 + 1e-9
    }
}

/// Compares the actual and planned times of the same traversed road intervals.
/// A slow city approach therefore does not penalize a still-untraveled motorway.
struct RoadETAPaceTracker {
    private var routeID: UUID?
    private var previous: (distance: Double, timestamp: Date)?
    private var actualSeconds = 0.0
    private var plannedSeconds = 0.0

    mutating func observe(route: NavigationRoute, distance: Double, location: NavigationLocation,
                          reliable: Bool, isNavigating: Bool) -> Double {
        guard isNavigating else { self = Self(); return 1 }
        if routeID != route.id { self = Self(); routeID = route.id }
        guard reliable, location.speed.isFinite, location.speed >= 1,
              distance.isFinite, location.accuracy.isFinite, (0...35).contains(location.accuracy) else {
            previous = nil
            return multiplier
        }
        defer { previous = (distance, location.timestamp) }
        guard let previous else { return multiplier }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        let traveled = distance - previous.distance
        guard elapsed > 0, elapsed <= 10, traveled >= 1, traveled <= max(50, elapsed * 60) else {
            return multiplier
        }
        let planned = RoadRouteETA.drivingTime(route, from: previous.distance, through: distance)
        guard planned.isFinite, planned > 0 else { return multiplier }
        // Retain approximately five minutes of evidence, without keeping location history.
        let retained = actualSeconds > 300 ? max(0, 1 - elapsed / 300) : 1
        actualSeconds = actualSeconds * retained + elapsed
        plannedSeconds = plannedSeconds * retained + planned
        return multiplier
    }

    private var multiplier: Double {
        guard actualSeconds >= 45, plannedSeconds >= 20 else { return 1 }
        let ratio = min(1.8, max(0.65, actualSeconds / plannedSeconds))
        return 1 + (ratio - 1) * 0.55
    }
}
