#if os(iOS)
import Foundation

/// Resolving the service time zone can be substituted by critical tests without
/// changing the quote's full routing, closure, preference and EV pipeline.
typealias VoicePlanningTimeResolver = @MainActor (JourneyTimeMode, Date, Coordinate) async throws -> ValhallaPlanningTime

extension NavigationSession {
    func voiceRouteEstimate(
        preferences: RoutingPreferences,
        removingWaypointID: UUID? = nil,
        planningTimeResolver: VoicePlanningTimeResolver = { mode, date, coordinate in
            try await ValhallaPlanningTime.resolved(mode: mode, date: date, coordinate: coordinate)
        }
    ) async -> TimeInterval? {
        guard !Task.isCancelled, state.transportMode != .transit,
              let destination = state.destination else { return nil }
        let before = VoicePlanSnapshot(self)
        let active = state.status == .navigating
        guard active || state.status == .routePreview else { return nil }
        let origin: Coordinate?
        if active { origin = voiceEditingLocation?.coordinate }
        else { origin = await resolvedRouteOriginCoordinate(for: before.mode) }
        guard let origin, origin.isValidParkedCarCoordinate,
              !Task.isCancelled, before.matchesPlan(self), state.route?.id == before.route?.id else { return nil }

        // calculateRoutes also resolves access points and recalculates charging
        // stops. Run it against an isolated state instead of temporarily changing
        // the driver's live preferences or restoring them across suspension.
        let quote = makeVoiceQuoteSession(preferences: preferences, removingWaypointID: removingWaypointID)
        let remainingStops: [Coordinate]? = active
            ? unvisitedStops(from: origin).filter { $0.id != removingWaypointID }.map(\.coordinate) : nil
        do {
            if !active {
                quote.state.navigationTarget = await quote.resolveAccessTarget(
                    for: destination, mode: before.mode, from: origin)
            }
            try Task.checkCancellation()
            let target = quote.destinationRouteCoordinate(for: destination)
            let time: ValhallaPlanningTime?
            let preferenceDate: Date?
            if active {
                // A real reroute starts now, regardless of the original plan's departure date.
                time = nil
                preferenceDate = nil
            } else {
                time = try await planningTimeResolver(before.journeyTimeMode, before.journeyTargetTime,
                    before.journeyTimeMode == .arriveBy ? target : origin)
                preferenceDate = before.journeyTimeMode == .now ? Date() : before.journeyTargetTime
            }
            let routes = try await RoadRoutingContext.$planningTime.withValue(time) {
                try await RoadRoutingContext.$preferenceDate.withValue(preferenceDate) {
                    try await RoadRoutingContext.$publishesAssessments.withValue(false) {
                        try await quote.calculateRoutes(from: origin, to: target, through: remainingStops,
                            commitEVStops: false, publishDiagnostics: false)
                    }
                }
            }
            guard !Task.isCancelled, before.matchesPlan(self), state.route?.id == before.route?.id,
                  let duration = routes.first?.expectedTravelTime, duration.isFinite, duration >= 0 else { return nil }
            return duration
        } catch { return nil }
    }

    private func makeVoiceQuoteSession(preferences: RoutingPreferences, removingWaypointID: UUID?) -> NavigationSession {
        let address = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: address) ?? URL(string: "https://valhalla1.openstreetmap.de")!
        let quote = NavigationSession(dependencies: .live(routeEndpoint: endpoint, trafficAPIKey: nil,
            transitProvider: transitProvider, transitDataProvider: transitDataProvider))
        // No location startup, speech, Live Activity, history hooks or persistence.
        quote.voice.setEnabled(false)
        quote.locationManager.onAuthorization = nil
        quote.locationManager.onLocation = nil
        quote.locationManager.onHeading = nil
        quote.locationManager.onFailure = nil
        quote.trafficProvider = nil
        quote.routeProvider = routeProvider
        quote.state.transportMode = state.transportMode
        quote.state.status = state.status
        quote.state.location = state.location
        quote.state.route = state.route
        quote.state.routeOrigin = state.routeOrigin
        quote.state.destination = state.destination
        quote.state.navigationTarget = state.navigationTarget
        quote.state.waypoints = state.waypoints.filter { $0.id != removingWaypointID }
        quote.state.pendingWaypointIDs = state.pendingWaypointIDs.filter { $0 != removingWaypointID }
        quote.state.waypointNavigationTargets = state.waypointNavigationTargets.filter { $0.key != removingWaypointID }
        // Preview recalculates charging stops from scratch. Active navigation
        // preserves them as candidates while the EV engine rechecks reachability.
        quote.state.evChargingStops = state.status == .navigating ? state.evChargingStops : []
        quote.state.routingPreferences = preferences
        quote.state.journeyTimeMode = state.journeyTimeMode
        quote.state.journeyTargetTime = state.journeyTargetTime
        quote.knownRoadClosures = knownRoadClosures
        quote.evBatteryEstimate = evBatteryEstimate
        quote.tripSession = tripSession
        quote.previousRouteMatch = previousRouteMatch
        quote.state.routeMatch = state.routeMatch
        quote.state.mapMatchingResult = state.mapMatchingResult
        return quote
    }
}
#endif
