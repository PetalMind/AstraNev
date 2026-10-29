#if DEBUG && os(iOS)
import Foundation

/// An explicit UI regression scenario for the physical-device test runner.
/// Only the new session's in-memory plan changes. Routing uses the live provider
/// after the test presses the ordinary "Wyznacz trasę" button.
@MainActor
enum IOSDebugRoutePlanningScenario {
    static func prepare(_ navigationStore: NavigationStore) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NAVIASTRA_ROUTE_UI_AUDIT"] == "1" else { return }
        let count = environment["NAVIASTRA_ROUTE_UI_WAYPOINTS"] == "8" ? 8 : 0
        let state = navigationStore.state
        state.transportMode = .car
        state.routingPreferences = RoutingPreferences()
        state.routeOrigin = RoutePoint(
            Destination(name: "Łódź — początek kontroli",
                        coordinate: Coordinate(latitude: 51.7593, longitude: 19.4560)),
            source: .search)
        navigationStore.selectDestination(
            Destination(name: "Łódź — cel kontroli",
                        coordinate: Coordinate(latitude: 51.7760, longitude: 19.4545)),
            applyConfiguredMode: false)
        state.waypoints = (0..<count).map { index in
            Destination(name: "Przystanek kontrolny \(index + 1)",
                        coordinate: Coordinate(latitude: 51.7610 + Double(index) * 0.0017,
                                               longitude: 19.4558 - Double(index) * 0.0001))
        }
    }
}
#endif
