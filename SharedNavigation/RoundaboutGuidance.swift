import Foundation

nonisolated struct RoundaboutGuidance: Codable, Hashable, Sendable {
    /// Clockwise degrees relative to the direction of approach: 0 straight, 90 right.
    var exitAngle: Double?
    var clockwise: Bool?
    var exitCount: Int?
}
