import Foundation

/// Only use metrics returned by a route/matrix provider or measured along a
/// resolved route. Missing or malformed values never become a zero-length trip.
nonisolated struct RoutedTravelMetrics: Equatable, Sendable {
    let time: TimeInterval
    let distance: Double

    init?(time: TimeInterval?, distance: Double?) {
        guard let time, time.isFinite, (0...31_536_000).contains(time),
              let distance, distance.isFinite, (0...400_000_000).contains(distance) else { return nil }
        self.time = time
        self.distance = distance
    }
}
