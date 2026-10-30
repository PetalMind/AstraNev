import Foundation

nonisolated struct RouteETAObservation: Codable, Sendable {
    let elapsedSeconds: Double
    let remainingSeconds: Double
    let routeID: UUID
    let trafficCoverage: Double?

    var isValid: Bool {
        elapsedSeconds.isFinite && (0...604_800).contains(elapsedSeconds) &&
        remainingSeconds.isFinite && (0...604_800).contains(remainingSeconds) &&
        (trafficCoverage.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
}

/// Observed predictions are replayed against an actual arrival, not a synthetic target.
/// No coordinates or destination names are needed to measure ETA quality.
nonisolated struct RouteQualityMeasurement: Codable, Sendable {
    let observations: [RouteETAObservation]

    var isValid: Bool {
        observations.count <= 1_440 && observations.allSatisfy(\.isValid) &&
        zip(observations, observations.dropFirst()).allSatisfy { $0.elapsedSeconds < $1.elapsedSeconds }
    }

    func arrivalErrors(actualDuration: TimeInterval) -> [Double] {
        guard isValid, actualDuration.isFinite, actualDuration >= 0 else { return [] }
        return observations.filter { $0.elapsedSeconds < actualDuration }.map {
            actualDuration - ($0.elapsedSeconds + $0.remainingSeconds)
        }
    }
}

nonisolated struct RouteQualityRecorder {
    private(set) var observations: [RouteETAObservation] = []
    private var planChanged = false

    mutating func invalidateForPlanChange() {
        planChanged = true
        observations.removeAll()
    }

    mutating func observe(elapsed: Double, remaining: Double, routeID: UUID, trafficCoverage: Double?) {
        let sample = RouteETAObservation(elapsedSeconds: elapsed, remainingSeconds: remaining,
                                         routeID: routeID, trafficCoverage: trafficCoverage)
        guard !planChanged, sample.isValid else { return }
        if let last = observations.last {
            guard elapsed > last.elapsedSeconds,
                  elapsed - last.elapsedSeconds >= 60 || last.routeID != routeID else { return }
        }
        if observations.count >= 1_440 {
            observations = observations.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        observations.append(sample)
    }

    var measurement: RouteQualityMeasurement? {
        observations.isEmpty ? nil : RouteQualityMeasurement(observations: observations)
    }
}

nonisolated struct RouteQualityReplay: Codable, Sendable {
    struct Journey: Codable, Sendable {
        let id: UUID
        let actualDuration: Double
        let initialErrorSeconds: Double
        let meanAbsoluteErrorSeconds: Double
        let observations: Int
        let reroutes: Int
        let recordedFraction: Double
        let measurement: RouteQualityMeasurement
    }
    let journeys: [Journey]
    var meanInitialAbsoluteError: Double? {
        guard !journeys.isEmpty else { return nil }
        return journeys.reduce(0) { $0 + abs($1.initialErrorSeconds) } / Double(journeys.count)
    }

    @MainActor static func replay(_ trips: [TripRecord]) -> Self {
        Self(journeys: trips.compactMap { trip in
            guard trip.arrived, trip.transportMode == .car, trip.recordingCoverage >= 0.8,
                  let measurement = trip.routingQuality else { return nil }
            let errors = measurement.arrivalErrors(actualDuration: trip.duration)
            guard let first = errors.first else { return nil }
            return Journey(id: trip.id, actualDuration: trip.duration, initialErrorSeconds: first,
                meanAbsoluteErrorSeconds: errors.reduce(0) { $0 + abs($1) } / Double(errors.count),
                observations: errors.count, reroutes: trip.rerouteCount,
                recordedFraction: trip.recordingCoverage, measurement: measurement)
        })
    }
}

extension NavigationSession {
    func recordRouteQuality() {
        guard state.transportMode == .car, state.status == .navigating,
              let route = state.route, let progress = state.progress, let trip = tripSession else { return }
        tripSession?.routeQuality.observe(elapsed: Date().timeIntervalSince(trip.startedAt),
            remaining: progress.remainingTime, routeID: route.id,
            trafficCoverage: state.routeReliability?.coverage.corridorFraction)
    }
}
