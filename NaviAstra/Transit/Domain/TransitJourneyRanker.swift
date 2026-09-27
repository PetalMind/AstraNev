import Foundation
import OSLog

enum TransitJourneyRanker {
    private static let logger = Logger(subsystem: "STDMSolution.NaviAstra", category: "TransitRouting")

    static func ranked(_ journeys: [TransitJourney], profile: TransitRouteProfile,
                       limit: Int = 5) -> [TransitJourney] {
        let candidates = journeys.filter { $0.legs.contains(where: { $0.isTransit }) || $0.legs.contains(where: { $0.mode == .walk }) }
        let unique = deduplicated(candidates)
        let ordered = unique.sorted {
            score($0, profile: profile) < score($1, profile: profile)
        }
        let result = diversified(ordered, limit: limit)
        logger.info("Ranked journeys; received=\(journeys.count, privacy: .public) valid=\(unique.count, privacy: .public) selected=\(result.count, privacy: .public)")
        return result
    }

    static func score(_ journey: TransitJourney, profile: TransitRouteProfile) -> Double {
        let risk = transferRiskPenalty(journey.legs)
        let positiveDelay = journey.legs.compactMap(\.delaySeconds).reduce(0) { $0 + max(0, $1) }
        switch profile {
        case .balanced:
            return journey.duration + journey.walkingDuration * 0.35
                + journey.walkingDistance * 0.16 + journey.waitingDuration * 0.15
                + Double(journey.transfers) * 300 + risk + Double(positiveDelay) * 0.35
        case .fastest:
            return journey.duration + journey.walkingDuration * 0.1
                + journey.walkingDistance * 0.03 + Double(journey.transfers) * 100
                + risk + Double(positiveDelay) * 0.2
        case .leastWalking:
            return journey.duration * 0.45 + journey.walkingDuration * 1.9
                + journey.walkingDistance * 0.25 + Double(journey.transfers) * 220
                + risk + Double(positiveDelay) * 0.2
        case .fewestTransfers:
            return journey.duration * 0.55 + journey.walkingDuration * 0.25
                + journey.walkingDistance * 0.08 + Double(journey.transfers) * 720
                + risk + Double(positiveDelay) * 0.2
        }
    }

    static func transferRiskPenalty(_ legs: [TransitLeg]) -> Double {
        let rideIndices = legs.indices.filter { legs[$0].isTransit }
        guard rideIndices.count > 1 else { return 0 }
        var penalty = 0.0
        for index in 1..<rideIndices.count {
            let previousIndex = rideIndices[index - 1]
            let nextIndex = rideIndices[index]
            let previousRide = legs[previousIndex]
            let nextRide = legs[nextIndex]
            let walkingBetween = legs[(previousIndex + 1)..<nextIndex]
                .filter { $0.mode == .walk }
                .reduce(0.0) { $0 + $1.duration }
            let available = nextRide.estimatedDeparture.timeIntervalSince(previousRide.estimatedArrival)
            let margin = max(0, available - walkingBetween)
            penalty += max(0, 180 - margin) * 2.0
        }
        return penalty
    }

    private static func deduplicated(_ journeys: [TransitJourney]) -> [TransitJourney] {
        var seen = Set<String>()
        return journeys.filter { seen.insert(signature($0)).inserted }
    }

    private static func diversified(_ ordered: [TransitJourney], limit: Int) -> [TransitJourney] {
        guard limit > 0, !ordered.isEmpty else { return [] }
        var result: [TransitJourney] = []
        var seen = Set<String>()
        func append(_ journey: TransitJourney?) {
            guard let journey, result.count < limit else { return }
            let id = signature(journey)
            guard seen.insert(id).inserted else { return }
            result.append(journey)
        }

        append(ordered.first)
        append(ordered.min { $0.duration < $1.duration })
        append(ordered.min {
            ($0.walkingDuration, $0.walkingDistance, $0.duration)
                < ($1.walkingDuration, $1.walkingDistance, $1.duration)
        })
        append(ordered.min {
            ($0.transfers, $0.duration) < ($1.transfers, $1.duration)
        })
        for journey in ordered { append(journey) }
        return result
    }

    private static func signature(_ journey: TransitJourney) -> String {
        journey.legs.map { leg in
            [leg.mode.rawValue, leg.routeID ?? leg.line ?? "", leg.tripID ?? "",
             leg.fromStop, leg.toStop,
             String(Int(leg.scheduledDeparture.timeIntervalSince1970))]
                .joined(separator: "|")
        }.joined(separator: ";")
    }
}
