#if os(iOS)
import Foundation

/// A confirmation belongs to one journey and expires; a late "tak" cannot edit another trip.
struct VoiceDialogContext: Equatable {
    let destinationID: UUID?
    let routeID: UUID?
    let waypointIDs: [UUID]
    let pendingWaypointIDs: [UUID]
    let preferences: RoutingPreferences
    let mode: TransportMode
    let status: NavigationStatus
    let createdAt: Date

    @MainActor init(state: NavigationState, now: Date = Date()) {
        destinationID = state.destination?.id
        routeID = state.route?.id
        waypointIDs = state.waypoints.map(\.id)
        pendingWaypointIDs = state.pendingWaypointIDs
        preferences = state.routingPreferences
        mode = state.transportMode
        status = state.status
        createdAt = now
    }

    @MainActor func matches(_ state: NavigationState, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return (0...90).contains(age) && destinationID == state.destination?.id &&
            routeID == state.route?.id && waypointIDs == state.waypoints.map(\.id) &&
            pendingWaypointIDs == state.pendingWaypointIDs &&
            preferences == state.routingPreferences && mode == state.transportMode && status == state.status
    }
}
#endif
