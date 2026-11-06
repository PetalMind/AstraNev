#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct VoiceDialogCriticalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func confirmationExpiresAndRejectsClockReversal() {
        let state = makeState()
        let context = VoiceDialogContext(state: state, now: now)
        #expect(context.matches(state, now: now))
        #expect(context.matches(state, now: now.addingTimeInterval(90)))
        #expect(!context.matches(state, now: now.addingTimeInterval(90.001)))
        #expect(!context.matches(state, now: now.addingTimeInterval(-1)))
    }

    @Test
    func destinationAndRouteReplacementInvalidateOldYes() {
        let state = makeState()
        let context = VoiceDialogContext(state: state, now: now)
        let destination = state.destination
        state.destination?.id = UUID()
        #expect(!context.matches(state, now: now))
        state.destination = destination
        state.route?.id = UUID()
        #expect(!context.matches(state, now: now))
    }

    @Test
    func waypointInsertionRemovalAndReorderingInvalidateConfirmation() {
        let state = makeState()
        let context = VoiceDialogContext(state: state, now: now)
        let original = state.waypoints
        state.waypoints.append(Destination(name: "Nowy postój", coordinate: .init(latitude: 52.003, longitude: 21)))
        #expect(!context.matches(state, now: now))
        state.waypoints = Array(original.reversed())
        #expect(!context.matches(state, now: now))
        state.waypoints = Array(original.dropFirst())
        #expect(!context.matches(state, now: now))
    }

    @Test
    func priorityStopChangesInvalidateConfirmationEvenWhenRouteIDIsUnchanged() {
        let state = makeState()
        state.pendingWaypointIDs = state.waypoints.map(\.id)
        let context = VoiceDialogContext(state: state, now: now)
        state.pendingWaypointIDs.removeFirst()
        #expect(!context.matches(state, now: now))
    }

    @Test
    func travelModePreferencesAndLifecycleInvalidateConfirmation() {
        let state = makeState()
        let context = VoiceDialogContext(state: state, now: now)
        state.transportMode = .walking
        #expect(!context.matches(state, now: now))
        state.transportMode = .car
        state.routingPreferences.avoidHighways = true
        #expect(!context.matches(state, now: now))
        state.routingPreferences.avoidHighways = false
        state.status = .rerouting
        #expect(!context.matches(state, now: now))
        state.status = .arrived
        #expect(!context.matches(state, now: now))
        state.status = .idle
        #expect(!context.matches(state, now: now))
    }

    @Test
    func normalProgressDoesNotInvalidateUnrelatedConfirmation() {
        let state = makeState()
        let context = VoiceDialogContext(state: state, now: now)
        state.location = NavigationLocation(coordinate: .init(latitude: 52.0001, longitude: 21),
            speed: 10, course: 0, accuracy: 5, timestamp: now.addingTimeInterval(3))
        state.estimatedArrival = now.addingTimeInterval(500)
        state.progress = RouteProgress(traveledDistance: 11, remainingDistance: 989,
            remainingTime: 500, distanceToNextManeuver: 50, nextManeuver: nil,
            geometryProgress: 0.01, geometryRouteID: state.route?.id)
        #expect(context.matches(state, now: now.addingTimeInterval(3)))
    }

    private func makeState() -> NavigationState {
        let state = NavigationState()
        state.status = .navigating
        state.transportMode = .car
        state.routingPreferences = RoutingPreferences()
        state.destination = Destination(name: "Cel", coordinate: .init(latitude: 52.01, longitude: 21))
        state.route = NavigationRoute(coordinates: [.init(latitude: 52, longitude: 21), .init(latitude: 52.01, longitude: 21)],
                                      distance: 1_112, expectedTravelTime: 600, maneuvers: [])
        state.waypoints = [
            Destination(name: "Pierwszy postój", coordinate: .init(latitude: 52.002, longitude: 21)),
            Destination(name: "Drugi postój", coordinate: .init(latitude: 52.005, longitude: 21))
        ]
        return state
    }
}

extension VoiceSavedNavigationCriticalTests {
    @Test
    func alternativeRouteRequiresConfirmationAndOnlyChangesThePreview() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let routes = prepareAlternativeRoutes(fixture)

        await fixture.submit("Inna trasa")
        #expect(fixture.assistant.canConfirm)
        #expect(fixture.session.state.route?.id == routes[0].id)
        #expect(fixture.session.state.status == .routePreview)

        await fixture.submit("Tak")
        #expect(fixture.session.state.route?.id == routes[1].id)
        #expect(fixture.session.state.status == .routePreview)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last == "Wybrano inny wariant trasy.")
        #expect(fixture.provider.requestCount == 0)
    }

    @Test
    func alternativeRouteDisappearingDuringConfirmationCannotBeApplied() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let routes = prepareAlternativeRoutes(fixture)
        await fixture.submit("Inna trasa")
        fixture.session.state.routeOptions = [routes[0]]

        await fixture.submit("Tak")

        #expect(fixture.session.state.route?.id == routes[0].id)
        #expect(fixture.session.state.status == .routePreview)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.contains("nie jest już dostępny") == true)
    }

    @Test
    func previewAlternativeConfirmationCannotSurviveStartingNavigation() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let routes = prepareAlternativeRoutes(fixture)
        await fixture.submit("Inna trasa")
        fixture.session.state.status = .navigating

        await fixture.submit("Tak")

        #expect(fixture.session.state.route?.id == routes[0].id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.provider.requestCount == 0)
        #expect(!fixture.replies.contains("Wybrano inny wariant trasy."))
    }

    @Test
    func cancellationAndMissingAlternativeLeaveThePreviewIntact() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let routes = prepareAlternativeRoutes(fixture)
        await fixture.submit("Inna trasa")
        await fixture.submit("Anuluj")
        await fixture.submit("Tak")
        #expect(fixture.session.state.route?.id == routes[0].id)
        #expect(!fixture.assistant.canConfirm)

        fixture.session.state.routeOptions = [routes[0]]
        await fixture.submit("Inna trasa")
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.session.state.route?.id == routes[0].id)
        #expect(fixture.replies.last?.contains("Nie ma teraz innego") == true)
    }

    private func prepareAlternativeRoutes(_ fixture: SavedVoiceFixture) -> [NavigationRoute] {
        let destination = Destination(name: "Cel", coordinate: .init(latitude: 52.02, longitude: 21))
        let first = SavedVoiceProvider.route(from: fixture.origin, to: destination.coordinate)
        var second = first
        second.id = UUID()
        second.coordinates.insert(.init(latitude: 52.01, longitude: 21.005), at: 1)
        second.expectedTravelTime += 120
        fixture.session.state.destination = destination
        fixture.session.state.route = first
        fixture.session.state.routeOptions = [first, second]
        fixture.session.state.status = .routePreview
        return [first, second]
    }
}
#endif
