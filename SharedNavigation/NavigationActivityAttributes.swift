#if os(iOS)
import ActivityKit
import Foundation

struct NavigationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var maneuver: Int
        var symbolName: String
        var instruction: String
        var roadName: String
        var maneuverDistance: Double?
        var remainingDistance: Double
        var remainingTime: TimeInterval
        var arrivalTime: Date
        var routeProgress: Double
        var isRerouting: Bool
        var roundabout: RoundaboutGuidance?
        var gpsSignalLost: Bool
    }
    var destinationName: String
}
#endif
