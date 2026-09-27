import Foundation

struct TransitousRouteProvider: TransitRouteProvider {
    let region: TransitRegion
    private let client: TransitousClient

    init(region: TransitRegion = .lodz,
         configuration: TransitousClientConfiguration = .init(),
         transport: TransitousTransport = URLSessionTransitousTransport()) {
        self.region = region
        self.client = TransitousClient(configuration: configuration, transport: transport)
    }

    func routes(from: Coordinate, to: Coordinate, time: Date, arriveBy: Bool,
                preferences: TransitRoutePreferences = .init(),
                cancellationToken: TransitPlanningCancellationToken? = nil) async throws -> [TransitJourney] {
        let response = try await client.plan(from: from, to: to, time: time,
                                             arriveBy: arriveBy, preferences: preferences,
                                             cancellationToken: cancellationToken)
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        let ranked = TransitJourneyRanker.ranked(try TransitousMapper.journeys(from: response),
                                                 profile: preferences.profile)
        guard !ranked.isEmpty else { throw TransitRouteError.noRoute }
        return ranked
    }
}

extension TransitRouteProvider {
    func calculateRoutes(from: Coordinate, to: Coordinate, departingAt: Date = Date(),
                         onProgress: TransitPlanningProgressHandler? = nil,
                         onProvisionalRoutes: TransitProvisionalRoutesHandler? = nil,
                         cancellationToken: TransitPlanningCancellationToken? = nil) async throws
        -> [NavigationRoute] {
        await onProgress?(.searchingConnections)
        let journeys = try await routes(from: from, to: to, time: departingAt,
                                        arriveBy: false, preferences: .init(),
                                        cancellationToken: cancellationToken)
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        let navigationRoutes = TransitNavigationRouteMapper.routes(from: journeys)
        await onProvisionalRoutes?(navigationRoutes)
        await onProgress?(nil)
        return navigationRoutes
    }

    func calculateRoutesArrivingBy(from: Coordinate, to: Coordinate, deadline: Date,
                                   onProgress: TransitPlanningProgressHandler? = nil,
                                   shouldContinue: @escaping TransitPlanningContinuation,
                                   cancellationToken: TransitPlanningCancellationToken? = nil) async throws
        -> [NavigationRoute] {
        await onProgress?(.searchingConnections)
        guard await shouldContinue() else { throw CancellationError() }
        let journeys = try await routes(from: from, to: to, time: deadline,
                                        arriveBy: true, preferences: .init(),
                                        cancellationToken: cancellationToken)
        try Task.checkCancellation()
        try cancellationToken?.checkCancellation()
        guard await shouldContinue() else { throw CancellationError() }
        let navigationRoutes = TransitNavigationRouteMapper.routes(from: journeys)
        await onProgress?(nil)
        return navigationRoutes
    }
}
