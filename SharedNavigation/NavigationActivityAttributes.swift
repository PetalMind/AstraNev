#if os(iOS)
import ActivityKit
import Foundation

nonisolated struct NavigationActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var maneuver: Int
        var symbolName: String
        var instruction: String
        var roadName: String
        var maneuverDistance: Double?
        var remainingDistance: Double?
        var remainingTime: TimeInterval?
        var arrivalTime: Date?
        var routeProgress: Double
        var isRerouting: Bool
        var roundabout: RoundaboutGuidance?
        var gpsSignalLost: Bool
        var routeSketch: NavigationActivityRouteSketch? = nil
        var movementBucket: Int = 0
    }
    var destinationName: String
}
#endif
