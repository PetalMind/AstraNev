#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

// Keep these integration cases in the same serialized suite as saved-place
// navigation: they share the fixture's temporary routing defaults.
extension VoiceSavedNavigationCriticalTests {
    @Test
    func exactContactStartsNavigationAndAnnouncesItsAddressWithoutAQuestion() async throws {
        let contact = resolvedContact(address: "ul. Przykładowa 12, Warszawa")
        var contactQueries: [String] = []
        let resolver = VoiceDestinationResolver(contacts: { query, _ in
            contactQueries.append(query)
            return .resolved(contact)
        }, places: { _, _ in
            Issue.record("Dopasowany kontakt nie może trafić do publicznej wyszukiwarki.")
            return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Ania Kowalska")

        #expect(contactQueries.count == 1)
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == contact.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(fixture.replies.count == 1)
        #expect(fixture.replies.last?.hasPrefix("Prowadzę do Ania Kowalska") == true)
        #expect(fixture.replies.last?.contains("ul. Przykładowa 12, Warszawa") == true)
        #expect(!fixture.replies.contains { $0.contains("?") })
    }

    @Test
    func contactWithoutAPostalAddressDoesNotSearchPublicPlacesOrStartNavigation() async throws {
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .unavailable(.noPostalAddress) },
            places: { _, _ in
                Issue.record("Kontakt bez adresu nie może zmienić się w publiczne wyszukiwanie osoby.")
                return []
            })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Ania Kowalska")

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(fixture.session.state.status != .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last == VoiceContactUnavailableReason.noPostalAddress.message)
    }

    @Test
    func failedContactGeocodingDoesNotFallBackToPublicPlaces() async throws {
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .unavailable(.geocodingFailed) },
            places: { _, _ in
                Issue.record("Błąd adresu kontaktu nie upoważnia do wyszukania publicznego imiennika.")
                return []
            })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Ania Kowalska")

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last == VoiceContactUnavailableReason.geocodingFailed.message)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test
    func contactWithTwoAddressesStartsAfterExplicitSelectionWithoutAnotherConfirmation() async throws {
        let home = resolvedContact(address: "ul. Domowa 1, Warszawa", label: "Dom", latitude: 52.02)
        let work = resolvedContact(address: "ul. Służbowa 2, Warszawa", label: "Praca", latitude: 52.03)
        let resolver = VoiceDestinationResolver(contacts: { _, _ in
            .ambiguous(results: [home, work], matchingContacts: 1, matchingAddresses: 2)
        }, places: { _, _ in
            Issue.record("Dwa adresy kontaktu powinny pozostać wyborem lokalnym.")
            return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Ania Kowalska")
        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(fixture.assistant.choices.map(\.destination.id) == [home.id, work.id])
        #expect(fixture.assistant.canConfirm)

        let repliesBeforeChoice = fixture.replies.count
        await fixture.submit("Wybierz drugi")
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == work.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(fixture.replies.count == repliesBeforeChoice + 1)
        #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
        #expect(fixture.replies.last?.contains("ul. Służbowa 2, Warszawa") == true)
        #expect(fixture.replies.last?.contains("?") == false)
    }

    @Test
    func partiallyGeocodedAmbiguousContactCannotBecomeAnAutomaticDestination() async throws {
        let contact = resolvedContact(address: "ul. Domowa 1, Warszawa")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in
            .ambiguous(results: [contact], matchingContacts: 1, matchingAddresses: 2)
        }, places: { _, _ in
            Issue.record("Nie wolno zastępować brakującego adresu kontaktem publicznym.")
            return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Ania Kowalska")

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test
    func postOfficeCommandChoosesTheNearestMatchingOfficeByRoadDistance() async throws {
        let distant = resolvedPostOffice(latitude: 52.01, roadDistance: 4_000)
        let nearest = resolvedPostOffice(latitude: 52.02, roadDistance: 2_000)
        var wrongCarrier = resolvedPostOffice(latitude: 52.001, roadDistance: 100)
        wrongCarrier.brand = "InPost"
        wrongCarrier.destination.name = "InPost"
        var locker = resolvedPostOffice(latitude: 52.002, roadDistance: 200)
        locker.category = "parcel_locker"
        locker.destination.name = "Automat paczkowy Poczta Polska"
        var searchOrigins: [Coordinate?] = []
        let resolver = VoiceDestinationResolver(contacts: { _, _ in
            Issue.record("Nazwa marki pocztowej nie powinna być wyszukiwana jako kontakt.")
            return .noMatch
        }, places: { _, context in
            searchOrigins.append(context.origin)
            return [wrongCarrier, locker, distant, nearest]
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Poczty Polskiej")

        #expect(searchOrigins == [fixture.origin])
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == nearest.id)
        #expect(fixture.session.state.destination?.poi?.category == "post_office")
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.count == 1)
        #expect(!fixture.replies.contains { $0.contains("?") })
    }

    @Test
    func uniqueExactPublicPlaceStartsNavigationWithoutConfirmation() async throws {
        let place = resolvedPublicPlace("Muzeum Historii Żeglarstwa")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { _, _ in [place] })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Muzeum Historii Żeglarstwa")

        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == place.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
    }

    @Test
    func unrelatedProviderResultsCannotStartNavigationToAPostOffice() async throws {
        var wrongCarrier = resolvedPostOffice(latitude: 52.01, roadDistance: 1_000)
        wrongCarrier.brand = "InPost"
        wrongCarrier.destination.name = "InPost"
        var locker = resolvedPostOffice(latitude: 52.02, roadDistance: 500)
        locker.category = "parcel_locker"
        locker.destination.name = "Automat paczkowy Poczta Polska"
        for candidate in [wrongCarrier, locker, resolvedPublicPlace("Poczta Polska", isPOI: false)] {
            let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { _, _ in [candidate] })
            let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
            defer { fixture.close() }

            await fixture.submit("Prowadź do Poczty Polskiej")

            #expect(fixture.provider.requestCount == 0)
            #expect(fixture.session.state.destination == nil)
            #expect(fixture.session.state.status != .navigating)
            #expect(!fixture.assistant.canConfirm)
            #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
        }
    }

    @Test
    func missingOrStaleGPSCannotSelectTheNearestOfficeUsingTheMapCenter() async throws {
        for hasStaleLocation in [false, true] {
            let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { _, _ in
                Issue.record("Brak aktualnego GPS powinien zatrzymać wybór najbliższej placówki przed wyszukiwaniem.")
                return []
            })
            let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
            defer { fixture.close() }
            fixture.session.state.searchMapCenter = fixture.origin
            fixture.session.state.location = hasStaleLocation
                ? NavigationLocation(coordinate: fixture.origin, speed: 0, course: 0, accuracy: 5,
                                     timestamp: .now.addingTimeInterval(-120)) : nil

            await fixture.submit("Prowadź do Poczty Polskiej")

            #expect(fixture.provider.requestCount == 0)
            #expect(fixture.session.state.destination == nil)
            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.replies.last?.contains("lokalizację") == true)
            #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func latePlaceSearchCannotReplaceAManuallySelectedRoute() async throws {
        let gate = ResolvedVoiceSearchGate()
        let place = resolvedPublicPlace("Muzeum Historii Żeglarstwa")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { _, _ in
            await gate.suspend()
            return [place]
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        fixture.assistant.submit("Prowadź do Muzeum Historii Żeglarstwa")
        let operation = try #require(fixture.assistant.task)
        await gate.waitUntilRequested()

        let replacement = Destination(name: "Ręcznie wybrany cel", coordinate: .init(latitude: 52.03, longitude: 21))
        fixture.session.selectDestination(replacement, applyConfiguredMode: false)
        let route = SavedVoiceProvider.route(from: fixture.origin, to: replacement.coordinate)
        fixture.session.state.route = route
        fixture.session.state.status = .routePreview
        gate.resume()
        await operation.value

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination?.id == replacement.id)
        #expect(fixture.session.state.route?.id == route.id)
        #expect(fixture.session.state.status == .routePreview)
        #expect(!fixture.assistant.canConfirm)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test(.timeLimit(.minutes(1)))
    func lostGPSDuringOfficeSearchPreventsAutomaticNavigation() async throws {
        let gate = ResolvedVoiceSearchGate()
        let office = resolvedPostOffice(latitude: 52.02, roadDistance: 2_000)
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { _, _ in
            await gate.suspend()
            return [office]
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        fixture.assistant.submit("Prowadź do Poczty Polskiej")
        let operation = try #require(fixture.assistant.task)
        await gate.waitUntilRequested()
        fixture.session.state.location = nil
        gate.resume()
        await operation.value

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(!fixture.assistant.canConfirm)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test
    func resolvedContactAndOfficeRouteFailuresNeverAnnounceSuccessfulGuidance() async throws {
        let contact = resolvedContact(address: "ul. Przykładowa 12, Warszawa")
        let office = resolvedPostOffice(latitude: 52.02, roadDistance: 2_000)
        for query in ["Prowadź do Ania Kowalska", "Prowadź do Poczty Polskiej"] {
            let resolver = VoiceDestinationResolver(contacts: { _, _ in .resolved(contact) },
                                                    places: { _, _ in [office] })
            let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
            defer { fixture.close() }
            fixture.provider.fails = true

            await fixture.submit(query)

            #expect(fixture.provider.requestCount > 0)
            #expect(fixture.session.state.status != .navigating)
            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.replies.last?.contains("Nie udało się") == true)
            #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
        }
    }

    private func resolvedContact(address: String, label: String = "Dom", latitude: Double = 52.02) -> SearchResult {
        SearchResult(destination: Destination(name: "Ania Kowalska", coordinate: .init(latitude: latitude, longitude: 21),
            address: address), street: nil, houseNumber: nil, city: "Warszawa", countryCode: "PL",
            isContact: true, contactAddressLabel: label)
    }

    private func resolvedPostOffice(latitude: Double, roadDistance: Double) -> SearchResult {
        SearchResult(destination: Destination(name: "Poczta Polska", coordinate: .init(latitude: latitude, longitude: 21),
            address: "ul. Pocztowa 1, Warszawa"), street: "Pocztowa", houseNumber: "1", city: "Warszawa", countryCode: "PL",
            isPOI: true, category: "post_office", brand: "Poczta Polska", travelDistance: roadDistance)
    }

    private func resolvedPublicPlace(_ name: String, isPOI: Bool = true) -> SearchResult {
        SearchResult(destination: Destination(name: name, coordinate: .init(latitude: 52.02, longitude: 21),
            address: "ul. Muzealna 1, Warszawa"), street: "Muzealna", houseNumber: "1", city: "Warszawa", countryCode: "PL",
            isPOI: isPOI, category: "museum")
    }
}

@MainActor
private final class ResolvedVoiceSearchGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation {
            suspended = $0
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if suspended != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}
#endif
