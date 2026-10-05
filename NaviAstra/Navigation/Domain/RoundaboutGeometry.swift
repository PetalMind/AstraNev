import Foundation

nonisolated enum RoundaboutGeometry {
    static func guidance(coordinates: [Coordinate], entry: Int, exit: Int,
                         exitEnd: Int, incomingBearing: Double?, outgoingBearing: Double?,
                         exitCount: Int?) -> RoundaboutGuidance {
        let count = exitCount.flatMap { $0 > 0 ? $0 : nil }
        guard entry >= 0, exit > entry, exit < coordinates.count else {
            return RoundaboutGuidance(exitCount: count)
        }
        let incoming = validBearing(incomingBearing) ?? approachBearing(coordinates, at: entry)
        let outgoing = validBearing(outgoingBearing) ?? departureBearing(coordinates, at: exit, end: exitEnd)
        let angle = incoming.flatMap { before in outgoing.map { normalize($0 - before) } }
        // Only segments within the roundabout contribute to circulation. No country default.
        var headings: [Double] = []
        for index in entry..<exit {
            if let heading = bearing(coordinates[index], coordinates[index + 1], minimumDistance: 0.5) {
                headings.append(heading)
            }
        }
        var signed = 0.0
        var absolute = 0.0
        for (before, after) in zip(headings, headings.dropFirst()) {
            let delta = normalize(after - before + 180) - 180
            guard abs(delta) <= 100 else { return RoundaboutGuidance(exitCount: count) }
            signed += delta
            absolute += abs(delta)
        }
        // Reject nearly straight or inconsistent geometry, including ambiguous mini-roundabouts.
        let clockwise: Bool? = abs(signed) >= 20 && abs(signed) >= absolute * 0.7
            ? signed > 0 : nil
        return RoundaboutGuidance(exitAngle: angle, clockwise: clockwise, exitCount: count)
    }

    private static func approachBearing(_ coordinates: [Coordinate], at index: Int) -> Double? {
        guard index > 0 else { return nil }
        for previous in stride(from: index - 1, through: max(0, index - 12), by: -1) {
            if let bearing = bearing(coordinates[previous], coordinates[index], minimumDistance: 5) {
                return bearing
            }
        }
        return nil
    }

    private static func departureBearing(_ coordinates: [Coordinate], at index: Int, end: Int) -> Double? {
        let limit = min(end, coordinates.count - 1, index + 12)
        guard limit > index else { return nil }
        for next in (index + 1)...limit {
            if let bearing = bearing(coordinates[index], coordinates[next], minimumDistance: 5) {
                return bearing
            }
        }
        return nil
    }

    private static func bearing(_ from: Coordinate, _ to: Coordinate, minimumDistance: Double) -> Double? {
        guard from.distance(to: to) >= minimumDistance else { return nil }
        let latitude1 = from.latitude * .pi / 180
        let latitude2 = to.latitude * .pi / 180
        let longitude = (to.longitude - from.longitude) * .pi / 180
        let y = sin(longitude) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(longitude)
        return validBearing(normalize(atan2(y, x) * 180 / .pi))
    }

    private static func validBearing(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0..<360).contains(value) else { return nil }
        return value
    }

    private static func normalize(_ angle: Double) -> Double {
        (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
