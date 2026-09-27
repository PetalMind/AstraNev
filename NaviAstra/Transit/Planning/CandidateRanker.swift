import Foundation

nonisolated enum TransitCandidateRanker {
    static func candidateCost(_ candidate: TransitPlanCandidate, departingAt: Date,
                                      instances: [GTFSTripInstance]) -> Double {
        let rideSeconds = pathRideSeconds(candidate.label, instances: instances)
        let walking = candidate.label.walkingSeconds + candidate.destinationWalk.duration
        let total = candidate.arrival.timeIntervalSince(departingAt)
        let waiting = max(0, total - rideSeconds - walking)
        return rideSeconds + walking * 1.6 + waiting * 1.25
            + Double(candidate.label.transferCount) * 240
    }

    static func generalizedCost(_ route: NavigationRoute) -> Double {
        guard let journey = route.journey else { return route.expectedTravelTime }
        let rideSeconds = journey.legs.filter { $0.mode != "WALK" }
            .reduce(0.0) { $0 + $1.arrival.timeIntervalSince($1.departure) }
        return rideSeconds + journey.walkingDuration * 1.6 + journey.waitingDuration * 1.25
            + Double(journey.transferCount) * 240 + transferRiskPenalty(for: journey.legs)
    }

    static func transferRiskPenalty(for legs: [JourneyLeg]) -> Double {
        var penalty = 0.0
        for nextRideIndex in legs.indices where legs[nextRideIndex].mode != "WALK" {
            guard let previousRideIndex = legs[..<nextRideIndex].lastIndex(where: { $0.mode != "WALK" }) else {
                continue
            }
            let transferWalks = legs[(previousRideIndex + 1)..<nextRideIndex]
                .filter { $0.mode == "WALK" }
            let requiredTransfer = transferWalks.isEmpty
                ? 60.0
                : transferWalks.reduce(0.0) { $0 + max(0, $1.arrival.timeIntervalSince($1.departure)) }
            let available = legs[nextRideIndex].departure
                .timeIntervalSince(legs[previousRideIndex].arrival)
            let margin = max(0, available - requiredTransfer)
            let risk = max(0, (120 - margin) / 120)
            penalty += risk * risk * 240
            if transferWalks.contains(where: { $0.isTransfer && !$0.hasResolvedWalkingGeometry }) {
                penalty += 120
            }
        }
        return penalty
    }

    static func pathRideSeconds(_ label: TransitPathLabel,
                                        instances: [GTFSTripInstance]) -> Double {
        var total = 0.0
        var current: TransitPathLabel? = label
        while let node = current {
            if let ride = node.ride,
               instances.indices.contains(ride.instanceIndex) {
                let times = instances[ride.instanceIndex].times
                if times.indices.contains(ride.boardIndex), times.indices.contains(ride.alightIndex) {
                    total += max(0, times[ride.alightIndex].arrival
                        .timeIntervalSince(times[ride.boardIndex].departure))
                }
            }
            current = node.parent
        }
        return max(0, total)
    }

    static func transitSignature(_ route: NavigationRoute) -> String {
        route.journey?.legs.filter { $0.mode != "WALK" }
            .map { "\($0.tripID ?? $0.line ?? ""):\($0.from):\($0.to):\($0.departure.timeIntervalSince1970.rounded())" }
            .joined(separator: "|") ?? ""
    }

}
