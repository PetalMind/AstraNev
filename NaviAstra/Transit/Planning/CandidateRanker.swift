import Foundation

nonisolated enum TransitCandidateRanker {
    private struct RankedCandidate {
        let candidate: TransitPlanCandidate
        let cost: Double
        let order: Int
    }

    static func bestCandidates(
        _ candidates: [TransitPlanCandidate], departingAt: Date, limit: Int
    ) -> [(candidate: TransitPlanCandidate, cost: Double)] {
        guard limit > 0 else { return [] }
        var heap: [RankedCandidate] = []
        heap.reserveCapacity(min(candidates.count, limit))
        for (order, candidate) in candidates.enumerated() {
            let ranked = RankedCandidate(
                candidate: candidate,
                cost: candidateCost(candidate, departingAt: departingAt),
                order: order)
            if heap.count < limit {
                heap.append(ranked)
                siftUp(&heap, from: heap.count - 1)
            } else if ranksBefore(ranked, heap[0]) {
                heap[0] = ranked
                siftDown(&heap, from: 0)
            }
        }
        return heap.sorted {
            ranksBefore($0, $1)
        }.map { (candidate: $0.candidate, cost: $0.cost) }
    }

    private static func ranksBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        return lhs.cost == rhs.cost ? lhs.order < rhs.order : lhs.cost < rhs.cost
    }

    private static func siftUp(_ heap: inout [RankedCandidate], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard ranksBefore(heap[parent], heap[child]) else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private static func siftDown(_ heap: inout [RankedCandidate], from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var worseChild = left
            if right < heap.count, ranksBefore(heap[left], heap[right]) {
                worseChild = right
            }
            guard ranksBefore(heap[parent], heap[worseChild]) else { break }
            heap.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    static func latestDepartureComesBefore(_ lhs: NavigationRoute, _ rhs: NavigationRoute) -> Bool {
        let lhsDeparture = lhs.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
        let rhsDeparture = rhs.journey?.legs.first(where: { $0.mode != "WALK" })?.departure ?? .distantPast
        if lhsDeparture != rhsDeparture { return lhsDeparture > rhsDeparture }
        let lhsArrival = lhs.journey?.arrival ?? .distantFuture
        let rhsArrival = rhs.journey?.arrival ?? .distantFuture
        if lhsArrival != rhsArrival { return lhsArrival < rhsArrival }
        return generalizedCost(lhs) < generalizedCost(rhs)
    }

    static func candidateCost(_ candidate: TransitPlanCandidate, departingAt: Date) -> Double {
        let rideSeconds = candidate.label.rideSeconds
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

    static func transitSignature(_ route: NavigationRoute) -> String {
        route.journey?.legs.filter { $0.mode != "WALK" }
            .map { "\($0.tripID ?? $0.line ?? ""):\($0.from):\($0.to):\($0.departure.timeIntervalSince1970.rounded())" }
            .joined(separator: "|") ?? ""
    }

}
