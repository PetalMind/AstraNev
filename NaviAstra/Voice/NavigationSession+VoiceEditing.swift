#if os(iOS)
import Foundation

extension NavigationSession {
    /// Priority IDs only pin newly added stops until a reroute; they are not a
    /// list of unvisited stops. Resolve the next manual stop from route progress.
    var nextVoiceWaypoint: Destination? {
        guard state.status == .navigating || state.status == .rerouting else { return state.waypoints.first }
        guard let location = voiceEditingLocation else { return nil }
        let manualIDs = Set(state.waypoints.map(\.id))
        return unvisitedStops(from: location.coordinate).first { manualIDs.contains($0.id) }
    }

    func replaceVoiceDestination(_ destination: Destination) async {
        guard !Task.isCancelled, state.status == .navigating,
              voiceEditingLocation != nil else {
            state.errorMessage = "Czekam na aktualną, dokładną pozycję GPS i zakończenie przeliczania trasy."
            return
        }
        let before = VoicePlanSnapshot(self)
        let targets = await resolveAccessTarget(for: destination, mode: state.transportMode)
        guard !Task.isCancelled, before.matchesPlan(self), state.route?.id == before.route?.id,
              state.status == .navigating, requestGeneration == before.requestGeneration,
              let location = voiceEditingLocation else { return }
        state.destination = destination
        state.navigationTarget = targets
        state.evChargingStops = []
        tripSession?.destination = destination
        state.errorMessage = nil
        let applied = VoicePlanSnapshot(self)
        let expectedReroute = rerouteController.generation &+ 1
        await reroute(from: location.coordinate)
        finishVoiceEdit(before: before, applied: applied,
                        expectedRequest: before.requestGeneration, expectedReroute: expectedReroute)
    }

    func applyVoicePreferences(_ preferences: RoutingPreferences) async {
        guard !Task.isCancelled else { return }
        let active = state.status == .navigating
        let location = active ? voiceEditingLocation : nil
        guard (active || state.status == .routePreview), state.destination != nil,
              (!active || location != nil) else {
            state.errorMessage = "Czekam na aktualną, dokładną pozycję GPS i gotową trasę, aby ją zmienić."
            return
        }
        let before = VoicePlanSnapshot(self)
        // Commit preference persistence only after the route calculation succeeds.
        state.routingPreferences = preferences
        state.errorMessage = nil
        let applied = VoicePlanSnapshot(self)
        let expectedReroute = rerouteController.generation &+ (active ? 1 : 0)
        if let location { await reroute(from: location.coordinate) }
        else if let destination = state.destination { await preview(destination) }
        finishVoiceEdit(before: before, applied: applied,
                        expectedRequest: before.requestGeneration + (active ? 0 : 1), expectedReroute: expectedReroute)
    }

    func removeVoiceWaypoint(_ id: UUID) async {
        guard !Task.isCancelled else { return }
        let active = state.status == .navigating
        let location = active ? voiceEditingLocation : nil
        guard (active || state.status == .routePreview), state.destination != nil,
              (!active || location != nil) else {
            state.errorMessage = "Czekam na aktualną, dokładną pozycję GPS i gotową trasę, aby usunąć postój."
            return
        }
        guard nextVoiceWaypoint?.id == id else {
            state.errorMessage = "Kolejny postój się zmienił. Powtórz polecenie usunięcia postoju."
            return
        }
        let before = VoicePlanSnapshot(self)
        state.waypoints.removeAll { $0.id == id }
        state.pendingWaypointIDs.removeAll { $0 == id }
        state.waypointNavigationTargets.removeValue(forKey: id)
        tripSession?.waypoints.removeAll { $0.id == id }
        state.errorMessage = nil
        let applied = VoicePlanSnapshot(self)
        let expectedReroute = rerouteController.generation &+ (active ? 1 : 0)
        if let location { await reroute(from: location.coordinate) }
        else if let destination = state.destination { await preview(destination) }
        finishVoiceEdit(before: before, applied: applied,
                        expectedRequest: before.requestGeneration + (active ? 0 : 1), expectedReroute: expectedReroute)
    }

    func addVoiceWaypoint(_ destination: Destination) async {
        guard !Task.isCancelled else { return }
        let active = state.status == .navigating
        let location = active ? voiceEditingLocation : nil
        guard state.transportMode != .transit, (active || state.status == .routePreview),
              state.destination != nil, (!active || location != nil) else {
            state.errorMessage = "Dodanie postoju wymaga gotowej trasy samochodowej, pieszej lub rowerowej oraz aktualnej pozycji podczas prowadzenia."
            return
        }
        guard destination.coordinate.isValidParkedCarCoordinate, state.waypoints.count < 8 else {
            state.errorMessage = "Nie można dodać tego postoju. Trasa może mieć najwyżej osiem postojów."
            return
        }
        guard !state.waypoints.contains(where: { $0.coordinate == destination.coordinate }) else {
            state.errorMessage = "Ten postój jest już na trasie."
            return
        }
        let before = VoicePlanSnapshot(self)
        if active {
            state.waypoints.insert(destination, at: 0)
            state.pendingWaypointIDs.removeAll { $0 == destination.id }
            state.pendingWaypointIDs.insert(destination.id, at: 0)
            tripSession?.waypoints.insert(destination, at: 0)
        } else { state.waypoints.append(destination) }
        state.errorMessage = nil
        let applied = VoicePlanSnapshot(self)
        let expectedReroute = rerouteController.generation &+ (active ? 1 : 0)
        if let location { await reroute(from: location.coordinate) }
        else if let final = state.destination { await preview(final) }
        finishVoiceEdit(before: before, applied: applied,
                        expectedRequest: before.requestGeneration + (active ? 0 : 1), expectedReroute: expectedReroute)
    }

    var voiceEditingLocation: NavigationLocation? {
        guard let location = state.location,
              (-5...15).contains(Date().timeIntervalSince(location.timestamp)),
              location.accuracy.isFinite, (0...50).contains(location.accuracy),
              location.coordinate.isValidParkedCarCoordinate,
              !state.weakGPS else { return nil }
        return location
    }

    private func finishVoiceEdit(before: VoicePlanSnapshot, applied: VoicePlanSnapshot,
                                 expectedRequest: Int, expectedReroute: Int) {
        // A new trip, manual edit, or later reroute takes ownership of the plan.
        // An older failed request must not restore its snapshot over that work.
        guard requestGeneration == expectedRequest, rerouteController.isCurrent(expectedReroute),
              applied.matchesPlan(self) else { return }
        let active = before.status == .navigating
        guard active ? (state.status == .navigating || state.status == .rerouting)
            : (state.status == .routePreview || state.status == .routeCalculating || state.status == .error) else { return }
        let failed = state.errorMessage != nil || Task.isCancelled
        let retainsPreviousGeometry = active ? state.route?.id == before.route?.id : state.route == nil
        if failed && retainsPreviousGeometry {
            guard applied.pendingWaypointIDs == state.pendingWaypointIDs else { return }
            state.destination = before.destination
            state.navigationTarget = before.navigationTarget
            state.waypoints = before.waypoints
            state.pendingWaypointIDs = before.pendingWaypointIDs
            state.waypointNavigationTargets = before.waypointNavigationTargets
            state.evChargingStops = before.evChargingStops
            state.routingPreferences = before.preferences
            if tripSession?.id == before.tripID {
                if let destination = before.tripDestination { tripSession?.destination = destination }
                if let waypoints = before.tripWaypoints { tripSession?.waypoints = waypoints }
            }
            if !active {
                state.route = before.route
                state.routeOptions = before.routeOptions
                state.cameraState = before.cameraState
                state.progress = before.progress
                state.estimatedArrival = before.estimatedArrival
                state.transitProgress = before.transitProgress
                state.transitPlanningPhase = before.transitPlanningPhase
                state.laterTransitRoutes = before.laterTransitRoutes
                state.isLoadingLaterTransitRoutes = before.isLoadingLaterTransitRoutes
                state.didSearchLaterTransitRoutes = before.didSearchLaterTransitRoutes
                routeProgressTracker.invalidateGeometries()
            }
            state.status = before.status
            state.errorMessage = "Nie udało się zmienić trasy. Przywrócono poprzedni cel, postoje i ustawienia."
            if active || state.location != nil { updateProgress() }
            updateCameraIntent()
            refreshEnergyPolicy()
            updateLiveActivity()
        } else if state.status == .navigating || state.status == .routePreview {
            tripSession?.routeQuality.invalidateForPlanChange()
        }
        if before.preferences != state.routingPreferences,
           let data = try? JSONEncoder().encode(state.routingPreferences) {
            UserDefaults.standard.set(data, forKey: "routingPreferences")
        }
    }
}

/// Only plan fields are restored. GPS, trip distance and elapsed travel continue
/// updating during the request and must never be rolled back with the plan.
@MainActor
struct VoicePlanSnapshot {
    let destination: Destination?
    let navigationTarget: POINavigationTarget?
    let waypoints: [Destination]
    let pendingWaypointIDs: [UUID]
    let waypointNavigationTargets: [UUID: POINavigationTarget]
    let evChargingStops: [Destination]
    let preferences: RoutingPreferences
    let mode: TransportMode
    let routeOrigin: RoutePoint?
    let journeyTimeMode: JourneyTimeMode
    let journeyTargetTime: Date
    let route: NavigationRoute?
    let routeOptions: [NavigationRoute]
    let cameraState: NavigationCameraState
    let progress: RouteProgress?
    let estimatedArrival: Date?
    let transitProgress: TransitNavigationProgress?
    let transitPlanningPhase: TransitPlanningPhase?
    let laterTransitRoutes: [NavigationRoute]
    let isLoadingLaterTransitRoutes: Bool
    let didSearchLaterTransitRoutes: Bool
    let status: NavigationStatus
    let requestGeneration: Int
    let tripID: UUID?
    let tripDestination: Destination?
    let tripWaypoints: [Destination]?

    init(_ session: NavigationSession) {
        let state = session.state
        destination = state.destination
        navigationTarget = state.navigationTarget
        waypoints = state.waypoints
        pendingWaypointIDs = state.pendingWaypointIDs
        waypointNavigationTargets = state.waypointNavigationTargets
        evChargingStops = state.evChargingStops
        preferences = state.routingPreferences
        mode = state.transportMode
        routeOrigin = state.routeOrigin
        journeyTimeMode = state.journeyTimeMode
        journeyTargetTime = state.journeyTargetTime
        route = state.route
        routeOptions = state.routeOptions
        cameraState = state.cameraState
        progress = state.progress
        estimatedArrival = state.estimatedArrival
        transitProgress = state.transitProgress
        transitPlanningPhase = state.transitPlanningPhase
        laterTransitRoutes = state.laterTransitRoutes
        isLoadingLaterTransitRoutes = state.isLoadingLaterTransitRoutes
        didSearchLaterTransitRoutes = state.didSearchLaterTransitRoutes
        status = state.status
        requestGeneration = session.requestGeneration
        tripID = session.tripSession?.id
        tripDestination = session.tripSession?.destination
        tripWaypoints = session.tripSession?.waypoints
    }

    func matchesPlan(_ session: NavigationSession) -> Bool {
        let state = session.state
        return destination == state.destination && waypoints == state.waypoints &&
            preferences == state.routingPreferences && mode == state.transportMode &&
            routeOrigin == state.routeOrigin && journeyTimeMode == state.journeyTimeMode &&
            journeyTargetTime == state.journeyTargetTime && tripID == session.tripSession?.id
    }
}
#endif
