import Foundation
import CryptoKit

nonisolated struct DrivingLearningSettings: Codable, Equatable, Sendable {
    var enabled = false
    var shortcuts = true
    var roads = true
    var destinationApproach = true
    // The history stays on device. Remote map matching requires its own opt-in.
    var allowRemoteMatching = false
}

nonisolated struct DrivingPreferenceContext: Codable, Equatable, Sendable {
    let weekday: Int
    let hourBucket: Int
    let trafficLevel: String?
    var bucketHours = 2

    init(date: Date, trafficLevel: String? = nil) {
        let calendar = Calendar.current
        weekday = calendar.component(.weekday, from: date)
        hourBucket = calendar.component(.hour, from: date) / 2
        self.trafficLevel = trafficLevel
    }

    var title: String { "\(hourBucket * bucketHours):00–\(hourBucket * bucketHours + bucketHours - 1):59" }

    func affinity(to other: Self) -> Double {
        let weekend = weekday == 1 || weekday == 7
        let otherWeekend = other.weekday == 1 || other.weekday == 7
        let hourDifference = abs(hourBucket * bucketHours - other.hourBucket * other.bucketHours)
        let circularDifference = min(hourDifference, 24 - min(24, hourDifference))
        var score = exp(-Double(circularDifference) / 3) * (weekend == otherWeekend ? 1 : 0.5)
        if let trafficLevel, let otherLevel = other.trafficLevel, trafficLevel != otherLevel {
            score *= 0.5
        }
        return score
    }

    static func measuredTrafficLevel(_ traffic: TrafficSnapshot?, at date: Date = Date()) -> String? {
        guard let flow = traffic?.flow, flow.freeFlowSpeedKph > 0,
              abs(date.timeIntervalSince(flow.updatedAt)) <= 240,
              (flow.confidence ?? 0) >= 0.5 else { return nil }
        let ratio = Double(flow.currentSpeedKph) / Double(flow.freeFlowSpeedKph)
        return ratio >= 0.85 ? "free" : ratio >= 0.5 ? "moderate" : "heavy"
    }
}

/// OSM way + directed endpoint nodes survives graph-tile rebuilds. A graph edge ID
/// is scoped to its tile dataset and is only a fallback, never a global OSM ID.
nonisolated struct LearnedRoadSegment: Codable, Sendable {
    let id: String
    let coordinates: [Coordinate]
    let length: Double
    let names: [String]
}

nonisolated struct DrivingDeviation: Codable, Sendable, Identifiable {
    let id: String
    let entry: Coordinate
    let exit: Coordinate
    let preferred: [LearnedRoadSegment]
    let avoided: [LearnedRoadSegment]
    let elapsed: TimeInterval?
    var measuredBaselineElapsed: TimeInterval? = nil
    var kind: AlternativePathKind {
        let actual = preferred.reduce(0) { $0 + $1.length }
        let baseline = avoided.reduce(0) { $0 + $1.length }
        if baseline - actual >= max(50, baseline * 0.05) { return .distanceShortcut }
        if let elapsed, let baselineTime = measuredBaselineElapsed, baselineTime - elapsed >= max(15, baselineTime * 0.05) { return .timeShortcut }
        return .unknownPreference
    }
    var boundaryID: String { id.components(separatedBy: "|").first ?? id }
    // Observed elapsed time minus provider model time is not a measured saving.
    // No time-saving value is invented in the absence of comparable observations.
}

nonisolated struct LearnedDrivingTrip: Codable, Sendable, Identifiable {
    let id: UUID
    let destinationName: String
    let origin: Coordinate
    let destination: Coordinate
    let startedAt: Date
    let duration: TimeInterval
    let context: DrivingPreferenceContext
    let segments: [LearnedRoadSegment]
    let deviations: [DrivingDeviation]
    var confirmed: Bool
    var automaticPreferenceEligible = true
    var offeredVariants: [DrivingObservedVariant] = []
    var selectedVariantID: String? = nil
    var selectedAgainstAlternative = false

    var coordinates: [Coordinate] { segments.flatMap(\.coordinates) }
}

nonisolated struct DrivingRoutePattern: Identifiable, Sendable {
    let id: UUID
    let representative: LearnedDrivingTrip
    var trips: [LearnedDrivingTrip]
    var usageCount: Int { trips.count }
    var confirmed: Bool { trips.contains(where: \.confirmed) }
    var confidence: Double { DrivingEvidenceMath.metrics(trips: trips, at: Date()).confidence }
    var strength: Double { DrivingEvidenceMath.metrics(trips: trips, at: Date()).strength }
    var averageDuration: TimeInterval { trips.reduce(0) { $0 + $1.duration } / Double(trips.count) }
}

nonisolated struct DrivingRoadPreference: Identifiable, Sendable {
    let id: String
    let names: [String]
    let uses: Int
    let selfSelected: Int
    let avoided: Int
    let preference: Double
    let avoidance: Double
    var offeredCount = 0
    var chosenCount = 0
    var metrics = PreferenceMetrics()
    var lastUsedAt: Date? = nil
    var offeredCountKnown = false
}

nonisolated struct AlternativePathPreference: Identifiable, Sendable {
    let id: String
    let deviation: DrivingDeviation
    let uses: Int
    let acceptanceRate: Double
    let confidence: Double
    let averageObservedDuration: TimeInterval?
    var metrics = PreferenceMetrics()
    var confirmed = false
    var kind: AlternativePathKind { deviation.kind }
    var offeredCount: Int? = nil
    var chosenCount = 0
    var avoidedCount = 0
}

typealias DrivingShortcutPreference = AlternativePathPreference

nonisolated struct DrivingApproachPreference: Identifiable, Sendable {
    let id: UUID
    let destination: Coordinate
    let name: String
    let segments: [LearnedRoadSegment]
    var trips: [LearnedDrivingTrip]
    var approachBearing: Double = 0
    var entry: Coordinate? = nil
    var confidence: Double { DrivingEvidenceMath.metrics(trips: trips, at: Date()).confidence }
    var confirmed: Bool { trips.contains(where: \.confirmed) }
}

nonisolated enum DrivingLearningMath {
    static func alternativeID(boundary: String, segments: [LearnedRoadSegment]) -> String {
        let encoded = segments.map(\.id).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(encoded.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return boundary + "|" + digest
    }
    static func confidence(_ count: Int) -> Double {
        guard count >= 3 else { return 0 }
        return min(0.96, 1 - exp(-Double(count - 2) / 5))
    }

    static func weight(tripCount: Int, confirmed: Bool = false) -> Double {
        let learned: Double
        switch tripCount {
        case ..<10: learned = 0
        case 10..<50: learned = 0.05
        case 50..<200: learned = 0.15
        default: learned = 0.25
        }
        return confirmed ? max(0.15, learned) : learned
    }

    static func sameJourney(_ a: LearnedDrivingTrip, _ b: LearnedDrivingTrip) -> Bool {
        a.origin.distance(to: b.origin) <= 250 && a.destination.distance(to: b.destination) <= 150
    }

    static func similarity(_ a: [LearnedRoadSegment], _ b: [LearnedRoadSegment]) -> Double {
        let ids = Set(b.map(\.id))
        let length = a.reduce(0) { $0 + $1.length }
        guard length > 0 else { return 0 }
        return a.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.length } / length
    }

    static func patterns(_ trips: [LearnedDrivingTrip]) -> [DrivingRoutePattern] {
        var result: [DrivingRoutePattern] = []
        for trip in trips.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let index = result.firstIndex(where: {
                sameJourney($0.representative, trip) && similarity(trip.segments, $0.representative.segments) >= 0.85
                    && similarity($0.representative.segments, trip.segments) >= 0.85
            }) {
                result[index].trips.append(trip)
            } else {
                result.append(DrivingRoutePattern(id: trip.id, representative: trip, trips: [trip]))
            }
        }
        return result.sorted { $0.usageCount > $1.usageCount }
    }

    static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let x = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        let y = b.latitude - a.latitude
        return (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Directional geometric comparison allows candidate ranking without sending
    /// a recorded journey to the route server or assuming candidate OSM IDs.
    static func overlap(_ segments: [LearnedRoadSegment], geometry: RouteProgressGeometry,
                        from start: Double = 0) -> Double {
        var total = 0.0, shared = 0.0
        for segment in segments {
            let points = segment.coordinates
            guard points.count > 1, segment.length > 0 else { continue }
            let count = min(12, max(1, points.count - 1))
            for index in 0..<count {
                let begin = index * (points.count - 1) / count
                let end = max(begin + 1, (index + 1) * (points.count - 1) / count)
                let a = points[begin], b = points[end]
                let point = points[(begin + end) / 2]
                let portion = segment.length / Double(count)
                total += portion
                guard let projection = geometry.project(point, within: 25),
                      projection.distanceFromRoute <= 25, projection.alongRoute >= start,
                      let c = geometry.coordinate(at: max(0, projection.alongRoute - 8)),
                      let d = geometry.coordinate(at: min(geometry.length, projection.alongRoute + 8)),
                      RoadGeometryAlignment.isAligned(a, b, c, d, directed: true) else { continue }
                shared += portion
            }
        }
        return total > 0 ? shared / total : 0
    }
}

nonisolated enum DrivingDeviationDetector {
    static func detect(actual: [LearnedRoadSegment], proposed: [LearnedRoadSegment],
                       trace: [TripTracePoint]) -> [DrivingDeviation] {
        guard actual.count > 2, proposed.count > 2 else { return [] }
        let proposedIndexes = Dictionary(proposed.enumerated().map { ($0.element.id, $0.offset) },
                                         uniquingKeysWith: { first, _ in first })
        var result: [DrivingDeviation] = []
        var anchor: (actual: Int, proposed: Int)?
        for (index, segment) in actual.enumerated() {
            guard let proposedIndex = proposedIndexes[segment.id] else { continue }
            defer { anchor = (index, proposedIndex) }
            guard let anchor, index > anchor.actual + 1, proposedIndex > anchor.proposed,
                  let entry = actual[anchor.actual].coordinates.last,
                  let exit = segment.coordinates.first else { continue }
            let preferred = Array(actual[(anchor.actual + 1)..<index])
            let avoided = Array(proposed[(anchor.proposed + 1)..<proposedIndex])
            let length = preferred.reduce(0) { $0 + $1.length }
            // A very short excursion, a stop, or a loop is not a learned shortcut.
            guard length >= 500, entry.distance(to: exit) >= 200, !avoided.isEmpty else { continue }
            let nearby = trace.filter { point in
                preferred.contains { road in road.coordinates.contains { $0.distance(to: point.coordinate) <= 50 } }
            }
            var stopped = 0.0
            for (left, right) in zip(nearby, nearby.dropFirst()) {
                let dt = right.timestamp.timeIntervalSince(left.timestamp)
                if dt > 0, dt <= 30, (left.speedKph ?? .infinity) < 3 { stopped += dt }
            }
            guard stopped < 60 else { continue }
            let elapsed = nearby.first.flatMap { first in nearby.last.map { $0.timestamp.timeIntervalSince(first.timestamp) } }
            result.append(DrivingDeviation(id: DrivingLearningMath.alternativeID(
                boundary: actual[anchor.actual].id + "→" + segment.id, segments: preferred),
                entry: entry, exit: exit, preferred: preferred, avoided: avoided, elapsed: elapsed))
        }
        return result
    }
}
