import Foundation
import Testing
@testable import NaviAstra

/// Never calculate a journey from a camera position or an expired GPS fix.
@MainActor struct SearchLocationCriticalTests {
    private let current = Coordinate(latitude: 52.2297, longitude: 21.0122)
    private let remote = Coordinate(latitude: 50.0614, longitude: 19.9383)

    private func state(at now: Date = Date()) -> NavigationState {
        let state = NavigationState()
        state.isLocationAuthorized = true
        state.location = NavigationLocation(coordinate: current, speed: 0, course: -1,
                                            accuracy: 15, timestamp: now)
        return state
    }

    @Test func staleDeniedInvalidAndFutureLocationsCannotBecomeCurrentOrigin() {
        let now = Date()
        let state = state(at: now)
        #expect(SearchLocationContext.coordinate(in: state, at: now) == current)
        state.location?.timestamp = now.addingTimeInterval(-61)
        #expect(SearchLocationContext.coordinate(in: state, at: now) == nil)
        state.location?.timestamp = now.addingTimeInterval(10)
        #expect(SearchLocationContext.coordinate(in: state, at: now) == nil)
        state.location?.timestamp = now
        state.location?.accuracy = -1
        #expect(SearchLocationContext.coordinate(in: state, at: now) == nil)
        state.location?.accuracy = .nan
        #expect(SearchLocationContext.coordinate(in: state, at: now) == nil)
        state.location?.accuracy = 15
        state.isLocationAuthorized = false
        #expect(SearchLocationContext.coordinate(in: state, at: now) == nil)
    }

    @Test func cameraAndPreviousRouteNeverReplaceCurrentGPS() async {
        let state = state()
        state.searchMapCenter = remote
        state.routeOrigin = RoutePoint(Destination(name: "Poprzedni start", coordinate: remote), source: .currentLocation)
        let store = SearchStore(transitRepository: LocalTransitDataProvider())
        let context = await store.searchContext(navigation: state, places: [], recentSearches: [])
        #expect(context.origin == current)
        #expect(context.area == current)

        state.location?.timestamp = Date().addingTimeInterval(-600)
        let expired = await store.searchContext(navigation: state, places: [], recentSearches: [])
        #expect(expired.origin == nil)
        #expect(expired.area == nil)
    }

    @Test func explicitMapAreaScopesResultsButCannotFabricateDeparture() async {
        let state = state()
        let store = SearchStore(transitRepository: LocalTransitDataProvider())
        store.searchArea = remote
        let context = await store.searchContext(navigation: state, places: [], recentSearches: [])
        #expect(context.area == remote)
        #expect(context.origin == current)

        state.isLocationAuthorized = false
        let denied = await store.searchContext(navigation: state, places: [], recentSearches: [])
        #expect(denied.area == remote)
        #expect(denied.origin == nil)
    }
}
