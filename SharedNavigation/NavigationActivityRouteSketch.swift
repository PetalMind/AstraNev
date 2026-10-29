import Foundation

/// A small local diagram, with no geographic coordinates, tiles or network URLs.
nonisolated struct NavigationActivityRouteSketch: Codable, Hashable, Sendable {
    nonisolated struct Point: Codable, Hashable, Sendable {
        var x: Int
        var y: Int
    }
    var points: [Point]
    var puck: Point
    var maneuver: Point?
}

/// ActivityKit has a 4 KB payload limit. Leave room for attributes and encoding.
nonisolated enum NavigationActivityPayload {
    static let maximumBytes = 3_500
    static func isWithinBudget<T: Encodable>(_ value: T) -> Bool {
        guard let bytes = try? JSONEncoder().encode(value) else { return false }
        return bytes.count <= maximumBytes
    }
}
