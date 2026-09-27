import Foundation

protocol TransitRouteProviding: Sendable {
    var region: TransitRegion { get }

    func usingWalkingRoutingEndpoint(_ endpoint: URL) -> TransitRouteProviding

    func calculateRoutes(
        from: Coordinate,
        to: Coordinate,
        parkRide: Bool,
        departingAt: Date,
        onProgress: TransitPlanningProgressHandler?,
        onProvisionalRoutes: TransitProvisionalRoutesHandler?
    ) async throws -> [NavigationRoute]

    func calculateRoutesArrivingBy(
        from: Coordinate,
        to: Coordinate,
        deadline: Date,
        onProgress: TransitPlanningProgressHandler?,
        shouldContinue: @escaping TransitPlanningContinuation
    ) async throws -> [NavigationRoute]
}

protocol TransitDataProviding: Sendable {
    var region: TransitRegion { get }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed
    func departures(at stopID: String, limit: Int) async -> [TransitDeparture]
    func departures(at stopIDs: [String], limit: Int) async -> [TransitDeparture]
    func alerts(for stopID: String) async -> [String]
    func alerts(for stopIDs: [String]) async -> [String]
    func railwayScheduleAttribution() async -> String?
    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults
    func lineDetails(for routeID: String) async -> TransitLineDetails?
    func vehicleDetails(id: String) async -> TransitTripDetails?
    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails?
    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails?
}

extension TransitDataProviding {
    func departures(at stopID: String) async -> [TransitDeparture] {
        await departures(at: stopID, limit: 10)
    }

    func departures(at stopIDs: [String]) async -> [TransitDeparture] {
        await departures(at: stopIDs, limit: 10)
    }

    func alerts(for stopID: String) async -> [String] {
        await alerts(for: [stopID])
    }
}

extension TransitRouteProviding {
    func usingWalkingRoutingEndpoint(_ endpoint: URL) -> TransitRouteProviding {
        self
    }

    func calculateRoutes(from: Coordinate, to: Coordinate,
                         departingAt: Date) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, parkRide: false,
                                  departingAt: departingAt, onProgress: nil,
                                  onProvisionalRoutes: nil)
    }

    func calculateRoutes(from: Coordinate, to: Coordinate,
                         departingAt: Date,
                         onProgress: TransitPlanningProgressHandler?) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, parkRide: false,
                                  departingAt: departingAt, onProgress: onProgress,
                                  onProvisionalRoutes: nil)
    }

    func calculateRoutes(from: Coordinate, to: Coordinate,
                         departingAt: Date,
                         onProgress: TransitPlanningProgressHandler?,
                         onProvisionalRoutes: TransitProvisionalRoutesHandler?) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, parkRide: false,
                                  departingAt: departingAt, onProgress: onProgress,
                                  onProvisionalRoutes: onProvisionalRoutes)
    }

    func calculateRoutesArrivingBy(
        from: Coordinate,
        to: Coordinate,
        deadline: Date,
        onProgress: TransitPlanningProgressHandler?,
        shouldContinue: @escaping TransitPlanningContinuation
    ) async throws -> [NavigationRoute] {
        var lowerDeparture = deadline.addingTimeInterval(-18 * 60 * 60)
        var upperDeparture = deadline
        var bestRoutes: [NavigationRoute] = []
        for _ in 0..<10 {
            guard await shouldContinue() else { throw CancellationError() }
            let interval = upperDeparture.timeIntervalSince(lowerDeparture)
            guard interval > 60 else { break }
            let departure = lowerDeparture.addingTimeInterval(interval / 2)
            do {
                let candidates = try await calculateRoutes(
                    from: from, to: to, parkRide: false, departingAt: departure,
                    onProgress: onProgress, onProvisionalRoutes: nil)
                let eligible = candidates.filter { ($0.journey?.arrival ?? .distantFuture) <= deadline }
                    .sorted(by: TransitCandidateRanker.latestDepartureComesBefore)
                if let latest = eligible.first {
                    if bestRoutes.first.map({
                        TransitCandidateRanker.latestDepartureComesBefore(latest, $0)
                    }) ?? true {
                        bestRoutes = eligible
                    }
                    lowerDeparture = departure
                } else {
                    upperDeparture = departure
                }
            } catch TransitRoutingError.noJourney {
                upperDeparture = departure
            } catch TransitRoutingError.noJourneyBeforeArrivalDeadline {
                upperDeparture = departure
            }
        }
        guard await shouldContinue() else { throw CancellationError() }
        guard !bestRoutes.isEmpty else { throw TransitRoutingError.noJourneyBeforeArrivalDeadline }
        return bestRoutes
    }
}
