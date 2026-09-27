import Foundation

enum TransitNavigationRouteMapper {
    static func routes(from journeys: [TransitJourney]) -> [NavigationRoute] {
        journeys.map(route(from:))
    }

    static func route(from journey: TransitJourney) -> NavigationRoute {
        let transitLegs = journey.legs.filter(\.isTransit)
        let legacyLegs = journey.legs.map { leg in
            JourneyLeg(
                mode: legacyMode(for: leg),
                line: leg.line,
                from: leg.fromStop,
                to: leg.toStop,
                departure: leg.estimatedDeparture,
                arrival: leg.estimatedArrival,
                realTime: leg.realtimeAvailable,
                delaySeconds: leg.delaySeconds,
                coordinates: leg.geometry,
                routeID: leg.routeID,
                tripID: leg.tripID,
                lineColorHex: leg.lineColorHex,
                transitStops: leg.intermediateStops,
                hasResolvedWalkingGeometry: leg.mode == .walk && leg.geometry.count > 1,
                scheduledDeparture: leg.scheduledDeparture,
                scheduledArrival: leg.scheduledArrival,
                direction: leg.direction,
                operatorName: leg.operatorName,
                distance: leg.distance,
                isInterlined: leg.isInterlined)
        }
        let coordinates = journey.legs.reduce(into: [Coordinate]()) { result, leg in
            if result.last == leg.geometry.first {
                result.append(contentsOf: leg.geometry.dropFirst())
            } else {
                result.append(contentsOf: leg.geometry)
            }
        }
        let distance = journey.legs.reduce(0) { $0 + $1.distance }
        let legacyJourney = Journey(
            departure: journey.departure,
            arrival: journey.arrival,
            legs: legacyLegs,
            realtimeFeedAvailable: journey.realtimeAvailable,
            alertsFeedAvailable: !journey.alerts.isEmpty,
            alerts: journey.alerts,
            walkingDuration: journey.walkingDuration,
            waitingDuration: journey.waitingDuration,
            transferCount: journey.transfers,
            realtimeFreshness: journey.realtimeAvailable ? .live : .unavailable,
            originAccessStopID: transitLegs.first?.intermediateStops.first?.stopID,
            destinationAccessStopID: transitLegs.last?.intermediateStops.last?.stopID,
            sourceID: journey.id)
        return NavigationRoute(
            coordinates: coordinates,
            distance: distance,
            expectedTravelTime: journey.duration,
            maneuvers: [],
            journey: legacyJourney)
    }

    private static func legacyMode(for leg: TransitLeg) -> String {
        switch leg.mode {
        case .walk: "WALK"
        case .bus: "BUS"
        case .tram: "TRAM"
        case .train: "RAIL"
        case .suburbanRail: "SUBURBAN"
        case .metro: "SUBWAY"
        case .ferry: "FERRY"
        case .bicycle: "BIKE"
        case .car: "CAR"
        case .unknown: leg.sourceMode.uppercased()
        }
    }
}
