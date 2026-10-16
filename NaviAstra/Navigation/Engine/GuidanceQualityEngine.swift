import Foundation

nonisolated struct GuidanceQuality: Codable, Sendable {
    let preparationDistance: Double
    let laneDistance: Double
    let immediateDistance: Double
    let complexity: Int
    let nextTurnDistance: Double?
    let reasons: [String]
    func stage(at distance: Double) -> Int? {
        guard distance.isFinite, distance >= 0 else { return nil }
        if distance <= immediateDistance { return 2 }
        if distance <= laneDistance { return 1 }
        if distance <= preparationDistance { return 0 }
        return nil
    }
}

nonisolated enum GuidanceQualityEngine {
    static func evaluate(maneuver: Maneuver, followingDistance: Double?, speed: Double,
                         mode: TransportMode = .car) -> GuidanceQuality {
        let speed = speed.isFinite ? max(0, speed) : 0
        var complexity = 0, reasons: [String] = []
        if maneuver.kind.isExit || maneuver.kind == .merge { complexity += 2; reasons.append("Węzeł lub włączenie do ruchu") }
        if maneuver.kind.isRoundabout { complexity += 1; reasons.append("Rondo") }
        if maneuver.lanes.count >= 3 { complexity += 1; reasons.append("Kilka pasów ruchu") }
        if [.sharpLeft, .sharpRight, .uTurnLeft, .uTurnRight].contains(maneuver.kind) {
            complexity += 1; reasons.append("Ostry skręt lub zawracanie")
        }
        let following = followingDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let following, following < max(120, speed * 10) {
            complexity += 2; reasons.append("Kolejne manewry blisko siebie")
        }
        let road = mode == .car
        let preparation = road ? max(200, min(1_500, speed * (24 + Double(complexity) * 5))) : max(45, min(150, speed * 24))
        let lane = road ? max(80, min(preparation * 0.6, speed * (8 + Double(complexity) * 3))) : max(20, speed * 8)
        return GuidanceQuality(preparationDistance: preparation, laneDistance: lane,
            immediateDistance: road ? min(45, max(20, speed * 1.5)) : 12,
            complexity: complexity, nextTurnDistance: following, reasons: reasons)
    }
}
