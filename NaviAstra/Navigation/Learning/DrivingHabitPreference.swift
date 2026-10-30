import Foundation

/// Repeated observed geometry is evidence of familiarity, not proof that the
/// driver rejected a historical alternative. Only today's baseline is compared.
nonisolated enum DrivingHabitPreference {
    struct Habit: Sendable {
        let points: [Coordinate]
        let segments: [LearnedRoadSegment]
        let supportDays: Int
        let confidence: Double
        let relevance: Double
        let recency: Double

        var effective: Double { confidence * relevance * recency }
    }

    private struct Observation {
        let trip: LearnedDrivingTrip
        let day: Date
        let geometries: [RouteProgressGeometry]
        let relevance: Double
    }

    /// A hint always lies on a continuous, repeatedly observed part of a route.
    /// The caller must recalculate it with the current road restrictions.
    static func candidates(trips: [LearnedDrivingTrip], origin: Coordinate,
                           destination: Coordinate, context: DrivingPreferenceContext,
                           baseline: NavigationRoute, date: Date = Date()) -> [Habit] {
        let baselineGeometry = RouteProgressGeometry(baseline)
        guard baselineGeometry.length.isFinite, baselineGeometry.length > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let observations = trips.compactMap { trip -> Observation? in
            let age = date.timeIntervalSince(trip.startedAt)
            // A known temporary detour stays ineligible, including after recovery.
            guard trip.automaticPreferenceEligible, age >= 0, age <= 90 * 86_400,
                  trip.origin.distance(to: origin) <= 250,
                  trip.destination.distance(to: destination) <= 150 else { return nil }
            // A habit repeated on independent days remains evidence across
            // departure times; context adjusts its influence, not eligibility.
            let relevance = 0.5 + 0.5 * context.affinity(to: trip.context)
            let geometries = continuousGroups(trip.segments).map {
                RouteProgressGeometry(coordinates: distinctCoordinates($0.flatMap(\.coordinates)))
            }.filter { $0.length.isFinite && $0.length >= 200 }
            guard !geometries.isEmpty else { return nil }
            return Observation(trip: trip, day: calendar.startOfDay(for: trip.startedAt),
                               geometries: geometries, relevance: relevance)
        }.sorted { $0.trip.startedAt > $1.trip.startedAt }
        guard Set(observations.map(\.day)).count >= 3,
              let newest = observations.first,
              date.timeIntervalSince(newest.trip.startedAt) <= 30 * 86_400 else { return [] }

        // Multiple journeys on one day cannot crowd independent observations out
        // of the bounded set of representative paths examined during routing.
        var seedDays: Set<Date> = []
        let seeds = observations.filter { seedDays.insert($0.day).inserted }.prefix(16)
        var examined: [[LearnedRoadSegment]] = []
        var habits: [Habit] = []
        for observation in seeds {
            for geometry in observation.geometries {
                for fragment in differingFragments(geometry, baseline: baselineGeometry) {
                    guard examined.count < 32 else { break }
                    guard !examined.contains(where: {
                        DrivingLearningMath.similarity(fragment, $0) >= 0.85 &&
                        DrivingLearningMath.similarity($0, fragment) >= 0.85
                    }) else { continue }
                    examined.append(fragment)
                    // Each supporting day must contain the whole directional
                    // fragment in one observation; gaps are never joined here.
                    var support: [Date: Observation] = [:]
                    for candidate in observations where candidate.geometries.contains(where: {
                        DrivingLearningMath.overlap(fragment, geometry: $0) >= 0.85
                    }) {
                        if support[candidate.day] == nil { support[candidate.day] = candidate }
                    }
                    guard support.count >= 3,
                          let last = support.values.map({ $0.trip.startedAt }).max(),
                          date.timeIntervalSince(last) <= 30 * 86_400 else { continue }
                    let path = RouteProgressGeometry(coordinates: distinctCoordinates(fragment.flatMap(\.coordinates)))
                    let points = [0.25, 0.5, 0.75].compactMap { fraction -> Coordinate? in
                        guard let point = path.coordinate(at: path.length * fraction),
                              (baselineGeometry.project(point, within: 40)?.distanceFromRoute ?? .infinity) > 40
                        else { return nil }
                        return point
                    }
                    guard !points.isEmpty else { continue }
                    let count = Double(support.count)
                    habits.append(Habit(points: points, segments: fragment, supportDays: support.count,
                        confidence: DrivingLearningMath.confidence(support.count),
                        relevance: support.values.reduce(0) { $0 + $1.relevance } / count,
                        recency: support.values.reduce(0) {
                            $0 + DrivingEvidenceMath.recency($1.trip.startedAt, at: date)
                        } / count))
                    if examined.count >= 32 { break }
                }
                if examined.count >= 32 { break }
            }
            if examined.count >= 32 { break }
        }
        return Array(habits.sorted {
            if $0.effective != $1.effective { return $0.effective > $1.effective }
            return $0.supportDays > $1.supportDays
        }.prefix(2))
    }

    /// Returns a bounded positive contribution (zero means no support). The
    /// caller retains its existing personal-ranking weight and ETA safeguards.
    /// Shared portions of the journey do not contribute to this assessment.
    static func assessment(route: NavigationRoute, habits: [Habit], from start: Double = 0) -> Double {
        let geometry = RouteProgressGeometry(route)
        return habits.reduce(0) { best, habit in
            let overlap = DrivingLearningMath.overlap(habit.segments, geometry: geometry, from: start)
            guard overlap >= 0.85 else { return best }
            return max(best, min(1, habit.effective * overlap))
        }
    }

    /// Adjacent stored segments share endpoints. Removing only consecutive
    /// duplicates prevents zero-length edges from diluting directional overlap.
    /// This runs within each observation, never across a GPS gap.
    private static func distinctCoordinates(_ coordinates: [Coordinate]) -> [Coordinate] {
        var result: [Coordinate] = []
        for point in coordinates {
            if let previous = result.last, previous.distance(to: point) <= 0.01 { continue }
            result.append(point)
        }
        return result
    }

    private static func continuousGroups(_ segments: [LearnedRoadSegment]) -> [[LearnedRoadSegment]] {
        var groups: [[LearnedRoadSegment]] = []
        for segment in segments {
            guard segment.coordinates.count > 1, segment.coordinates.allSatisfy(\.isValidValhallaCoordinate),
                  segment.length.isFinite, segment.length > 0 else {
                groups.append([])
                continue
            }
            let disconnected = groups.last?.last?.coordinates.last.flatMap { previous in
                segment.coordinates.first.map { previous.distance(to: $0) > 25 }
            } ?? false
            if groups.isEmpty || segment.startsObservation || disconnected { groups.append([]) }
            groups[groups.count - 1].append(segment)
        }
        return groups
    }

    private static func differingFragments(_ observed: RouteProgressGeometry,
                                            baseline: RouteProgressGeometry) -> [[LearnedRoadSegment]] {
        // Sampling is bounded for long journeys. Only an uninterrupted stretch
        // clearly outside the baseline corridor is retained, including approaches
        // that end at the destination without rejoining the earlier proposal.
        let cellCount = min(4_000, max(1, Int(ceil(observed.length / 40))))
        let step = observed.length / Double(cellCount)
        var runs: [(Double, Double)] = []
        var beginning: Double?
        for index in 0..<cellCount {
            let lower = Double(index) * step
            let upper = min(observed.length, lower + step)
            let away = [lower, (lower + upper) / 2, upper].allSatisfy { distance in
                guard let point = observed.coordinate(at: distance) else { return false }
                return (baseline.project(point, within: 45)?.distanceFromRoute ?? .infinity) > 45
            }
            if away {
                if beginning == nil { beginning = lower }
            } else if let start = beginning {
                runs.append((start, lower)); beginning = nil
            }
        }
        if let beginning { runs.append((beginning, observed.length)) }
        return runs.filter { $0.1 - $0.0 >= 200 }.sorted {
            $0.1 - $0.0 > $1.1 - $1.0
        }.prefix(4).compactMap { start, end in
            let points = observed.corridor(from: start, through: end)
            guard let first = points.first, let last = points.last,
                  first.distance(to: last) >= 100,
                  end - start <= first.distance(to: last) * 4 else { return nil }
            return DrivingTraceLearning.segments(coordinates: distinctCoordinates(points))
        }
    }
}
