import Foundation

nonisolated struct TrafficCoverage: Codable, Equatable, Sendable {
    let routeDistance: Double
    let monitoredDistance: Double
    let observedDistance: Double
    let freshDistance: Double
    let freshestMeasurement: Date?
    var routeFraction: Double { routeDistance > 0 ? freshDistance / routeDistance : 0 }
    var corridorFraction: Double { monitoredDistance > 0 ? freshDistance / monitoredDistance : 0 }

    static func measure(route: NavigationRoute, from start: Double, through end: Double? = nil,
                        traffic: TrafficSnapshot?, now: Date = .now, geometry cachedGeometry: RouteProgressGeometry? = nil) -> Self {
        let length = (cachedGeometry ?? RouteProgressGeometry(route)).length
        let lower = min(length, max(0, start)), upper = min(length, max(lower, end ?? length))
        let segments = (traffic?.routeFlowSegments ?? []).filter {
            $0.routeID == route.id && $0.startDistance.isFinite && $0.endDistance.isFinite &&
                $0.endDistance > $0.startDistance &&
                ($0.isRoadClosure || $0.currentSpeedKph.map { $0.isFinite && $0 >= 0 } == true)
        }
        func interval(_ segment: RouteTrafficSegment) -> (Double, Double)? {
            let a = max(lower, segment.startDistance), b = min(upper, segment.endDistance)
            return b > a ? (a, b) : nil
        }
        func unionLength(_ intervals: [(Double, Double)]) -> Double {
            var length = 0.0, cursor = lower
            for (a, b) in intervals.sorted(by: { $0.0 < $1.0 }) {
                length += max(0, b - max(cursor, a)); cursor = max(cursor, b)
            }
            return length
        }
        let fresh = segments.filter {
            guard let date = $0.measuredAt ?? traffic?.updatedAt else { return false }
            return (-5...240).contains(now.timeIntervalSince(date))
        }
        return Self(routeDistance: max(0, length - lower), monitoredDistance: upper - lower,
            observedDistance: unionLength(segments.compactMap(interval)),
            freshDistance: unionLength(fresh.compactMap(interval)),
            freshestMeasurement: fresh.compactMap { $0.measuredAt ?? traffic?.updatedAt }.max())
    }
}

nonisolated enum EvidenceLevel: String, Codable, Sendable {
    case unavailable, limited, supported, strong, blocked
    var title: String {
        switch self {
        case .unavailable: "Brak pomiarów ruchu"
        case .limited: "Ograniczone dane"
        case .supported: "Częściowe pokrycie pomiarami"
        case .strong: "Dobre pokrycie pomiarami"
        case .blocked: "Zamknięcie na trasie"
        }
    }
}

/// Evidence quality, not the probability of arriving on time or legal road availability.
nonisolated struct RouteReliability: Codable, Sendable {
    let level: EvidenceLevel
    let coverage: TrafficCoverage
    let trafficEvidence: Double?
    let hasConfirmedClosure: Bool
    let reasons: [String]

    static func evaluate(route: NavigationRoute, from start: Double, through end: Double? = nil,
                         traffic: TrafficSnapshot?, now: Date = .now, geometry cachedGeometry: RouteProgressGeometry? = nil) -> Self {
        let geometry = cachedGeometry ?? RouteProgressGeometry(route)
        let coverage = TrafficCoverage.measure(route: route, from: start, through: end, traffic: traffic, now: now, geometry: geometry)
        let closed = traffic.map { snapshot in
            ConfirmedRoadClosure.evidence(in: snapshot, route: route, now: now).contains {
                $0.distanceAhead(on: route, after: start, through: end ?? geometry.length, now: now) != nil
            }
        } ?? false
        let fraction = coverage.corridorFraction
        let level: EvidenceLevel = closed ? .blocked : coverage.freshDistance <= 0 ? .unavailable
            : fraction >= 0.8 ? .strong : fraction >= 0.5 ? .supported : .limited
        var reasons = [level.title]
        if coverage.freshDistance < coverage.routeDistance { reasons.append("Część pozostałej drogi bez świeżych pomiarów") }
        if coverage.observedDistance > coverage.freshDistance { reasons.append("Część pomiarów wygasła") }
        if traffic?.incidentDataAvailable != true { reasons.append("Brak potwierdzenia danych o zdarzeniach") }
        return Self(level: level, coverage: coverage,
                    trafficEvidence: coverage.freshDistance > 0 ? min(1, max(0, fraction)) : nil,
                    hasConfirmedClosure: closed, reasons: reasons)
    }
}

nonisolated struct ETAConfidence: Codable, Sendable {
    let level: EvidenceLevel
    let trafficCoverage: Double
    let gpsMatchQuality: Double?
    let uncertaintySeconds: Double? // Requires calibrated predicted-versus-actual arrival errors.
    let explanation: String

    static func evaluate(_ reliability: RouteReliability, gpsConfidence: Double? = nil) -> Self {
        let gps = gpsConfidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let wholeRouteFraction = reliability.coverage.routeFraction
        var level = reliability.level
        // Strong evidence in the next 25 minutes is not strong evidence for a 500 km ETA.
        if level != .blocked && level != .unavailable {
            if wholeRouteFraction < 0.5 || (gps ?? 1) < 0.4 { level = .limited }
            else if wholeRouteFraction < 0.8 && level == .strong { level = .supported }
        }
        return Self(level: level, trafficCoverage: wholeRouteFraction, gpsMatchQuality: gps,
                    uncertaintySeconds: nil, explanation: level == .blocked
                        ? "Czas wymaga przeliczenia po zamknięciu drogi"
                        : "Jakość danych ETA: \(level.title.lowercased())")
    }
}

nonisolated struct TrafficSamplingBudget: Sendable {
    let maximumRequests: Int
    static func resolved(isNavigating: Bool, isForeground: Bool, problemDetected: Bool) -> Self {
        Self(maximumRequests: !isForeground ? 24 : problemDetected ? 96 : isNavigating ? 64 : 40)
    }
}
