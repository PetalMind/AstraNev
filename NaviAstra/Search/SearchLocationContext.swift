import Foundation

/// A camera position or the start of an old route is never a current GPS fix.
enum SearchLocationContext {
    @MainActor static func coordinate(in state: NavigationState, at now: Date = Date()) -> Coordinate? {
        guard state.isLocationAuthorized, let location = state.location else { return nil }
        let age = now.timeIntervalSince(location.timestamp)
        guard (-5...60).contains(age), location.accuracy.isFinite,
              (0...1_000).contains(location.accuracy),
              (-90...90).contains(location.coordinate.latitude),
              (-180...180).contains(location.coordinate.longitude) else { return nil }
        return location.coordinate
    }
}
