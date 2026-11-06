#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

extension VoiceSavedNavigationCriticalTests {
    @Test
    func nextOnlyPreviewsAnAddressUntilAnExplicitChoiceStartsNavigation() async throws {
        let destinations = explicitChoiceDestinations()
        let fixture = try SavedVoiceFixture(places: destinations.map { SavedPlace(destination: $0) })
        defer { fixture.close() }

        await fixture.submit("Prowadź do działka")
        #expect(fixture.provider.requestCount == 0)
        await fixture.submit("Następna")
        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.contains("Drugi adres") == true)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })

        await fixture.submit("Wybierz drugi")

        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == destinations[1].id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
        #expect(fixture.replies.last?.contains("?") == false)
    }

    @Test
    func invalidChoiceClearsThePreviousPendingAddressBeforeAnyConfirmation() async throws {
        let fixture = try SavedVoiceFixture(places: explicitChoiceDestinations().map { SavedPlace(destination: $0) })
        defer { fixture.close() }
        await fixture.submit("Prowadź do działka")
        #expect(fixture.assistant.canConfirm)

        await fixture.submit("Wybierz trzeci")
        #expect(fixture.provider.requestCount == 0)
        #expect(!fixture.assistant.canConfirm)
        await fixture.submit("Tak")

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(fixture.session.state.status != .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test
    func changedOrExpiredChoiceContextCannotStartAnOldDestination() async throws {
        for changesJourney in [true, false] {
            let fixture = try SavedVoiceFixture(places: explicitChoiceDestinations().map { SavedPlace(destination: $0) })
            defer { fixture.close() }
            await fixture.submit("Prowadź do działka")
            if changesJourney {
                let replacement = Destination(name: "Ręcznie wybrany cel", coordinate: .init(latitude: 52.04, longitude: 21))
                fixture.session.selectDestination(replacement, applyConfiguredMode: false)
                fixture.session.state.route = SavedVoiceProvider.route(from: fixture.origin, to: replacement.coordinate)
                fixture.session.state.status = .routePreview
            } else {
                fixture.assistant.choiceContext = VoiceDialogContext(state: fixture.session.state,
                                                                     now: .now.addingTimeInterval(-120))
            }
            let expectedDestinationID = fixture.session.state.destination?.id
            let expectedRouteID = fixture.session.state.route?.id
            let expectedStatus = fixture.session.state.status

            await fixture.submit("Wybierz drugi")
            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.assistant.choices.isEmpty)
            await fixture.submit("Tak")

            #expect(fixture.provider.requestCount == 0)
            #expect(fixture.session.state.destination?.id == expectedDestinationID)
            #expect(fixture.session.state.route?.id == expectedRouteID)
            #expect(fixture.session.state.status == expectedStatus)
            #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
        }
    }

    @Test
    func explicitChoiceRouteFailureDoesNotAnnounceSuccessfulGuidance() async throws {
        let fixture = try SavedVoiceFixture(places: explicitChoiceDestinations().map { SavedPlace(destination: $0) })
        defer { fixture.close() }
        await fixture.submit("Prowadź do działka")
        fixture.provider.fails = true

        await fixture.submit("Wybierz drugi")

        #expect(fixture.provider.requestCount > 0)
        #expect(fixture.session.state.status != .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(fixture.replies.last?.contains("Nie udało się") == true)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedExplicitChoiceAcrossTaskGenerationsStartsOnlyOneRoute() async throws {
        let destinations = explicitChoiceDestinations()
        let fixture = try SavedVoiceFixture(places: destinations.map { SavedPlace(destination: $0) })
        defer { fixture.close() }
        await fixture.submit("Prowadź do działka")
        fixture.provider.suspends = true

        // Both commands arrive before either main-actor task gets to execute.
        fixture.assistant.submit("Wybierz drugi")
        let superseded = try #require(fixture.assistant.task)
        fixture.assistant.submit("Wybierz drugi")
        let operation = try #require(fixture.assistant.task)
        await fixture.provider.waitUntilRequested()
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.assistant.isApplyingChange)

        fixture.assistant.submit("Wybierz drugi")
        fixture.provider.suspends = false
        fixture.provider.resume()
        await superseded.value
        await operation.value

        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == destinations[1].id)
        #expect(fixture.session.state.status == .navigating)
        #expect(fixture.replies.filter { $0.hasPrefix("Prowadzę do ") }.count == 1)
        await fixture.submit("Wybierz drugi")
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == destinations[1].id)
        #expect(fixture.session.state.status == .navigating)
        #expect(fixture.replies.filter { $0.hasPrefix("Prowadzę do ") }.count == 1)
    }

    @Test
    func explicitStopChoiceStillAsksBeforeChangingTheJourney() async throws {
        let fixture = try SavedVoiceFixture(places: [])
        defer { fixture.close() }
        let destination = Destination(name: "Dotychczasowy cel", coordinate: .init(latitude: 52.05, longitude: 21))
        let route = SavedVoiceProvider.route(from: fixture.origin, to: destination.coordinate)
        fixture.session.state.destination = destination
        fixture.session.state.route = route
        fixture.session.state.status = .navigating
        let stops = explicitChoiceDestinations()
        fixture.assistant.choices = stops.map { VoiceAssistant.Choice(destination: $0, detail: $0.address ?? "", isStop: true) }
        fixture.assistant.choiceContext = VoiceDialogContext(state: fixture.session.state)

        await fixture.submit("Wybierz drugi")

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination?.id == destination.id)
        #expect(fixture.session.state.route?.id == route.id)
        #expect(fixture.session.state.waypoints.isEmpty)
        #expect(fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.contains("Drugi adres") == true)
        #expect(fixture.replies.last?.contains("Dodać postój?") == true)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    private func explicitChoiceDestinations() -> [Destination] {
        [Destination(name: "Działka", coordinate: .init(latitude: 52.02, longitude: 21), address: "Pierwszy adres"),
         Destination(name: "Działka", coordinate: .init(latitude: 52.03, longitude: 21), address: "Drugi adres")]
    }
}
#endif
