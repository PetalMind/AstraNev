#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

// Uses the existing serialized route fixture: these cases exercise actual
// destination mutation, not just wording or isolated string utilities.
extension VoiceSavedNavigationCriticalTests {
    @Test func localityAndBuildingCorrectionKeepWholeAddressUntilExplicitChoice() async throws {
        var queries: [String] = []
        let destination = voiceAddressResult(number: "26B", city: "Nowa Wieś")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
            queries.append(query)
            return query == "Długa 26B, Nowa Wieś" ? [destination] : []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }

        await fixture.submit("Prowadź do Długa 24 A")
        #expect(fixture.assistant.lastSearchQuery == "Długa 24A")
        #expect(fixture.assistant.destinationDialog != nil)
        #expect(!fixture.assistant.canConfirm)
        await fixture.submit("Nowa Wieś")
        #expect(fixture.assistant.lastSearchQuery == "Długa 24A, Nowa Wieś")
        await fixture.submit("nie, numer 26 B")
        #expect(queries == ["Długa 24A", "Długa 24A, Nowa Wieś", "Długa 26B, Nowa Wieś"])
        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.assistant.choices.map(\.destination.id) == [destination.id])
        await fixture.submit("Wybierz pierwszy")
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == destination.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(fixture.assistant.destinationDialog == nil)
    }

    @Test func secondLocalityReplacesFirstAndInterruptedCaptureKeepsDraft() async throws {
        var queries: [String] = []
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
            queries.append(query); return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        await fixture.submit("Nawiguj do Długa 24A")
        await fixture.submit("Nowa Wieś")
        fixture.assistant.captureEnded("Nasłuchiwanie zostało przerwane.")
        #expect(fixture.assistant.destinationDialog != nil)
        #expect(fixture.assistant.responseDismissalTask == nil)
        await fixture.submit("miejscowość Stara Wieś")
        #expect(queries.last == "Długa 24A, Stara Wieś")
        #expect(!fixture.assistant.lastSearchQuery.contains("Nowa Wieś"))
        #expect(fixture.provider.requestCount == 0)
    }

    @Test func rejectedAddressCannotBeConfirmedAndSpeakerTextIsNotALocality() async throws {
        var queries: [String] = []
        let destination = voiceAddressResult(number: "24A", city: "Nowa Wieś")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
            queries.append(query)
            return query == "Długa 24A" ? [destination, voiceAddressResult(number: "24A", city: "Stara Wieś")] : []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        await fixture.submit("Prowadź do Długa 24A")
        #expect(fixture.assistant.canConfirm)
        await fixture.submit("nie")
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.destinationDialog != nil)
        await fixture.submit("tak")
        #expect(fixture.provider.requestCount == 0)
        await fixture.submit("Powtórz polecenie")
        #expect(queries == ["Długa 24A"])
        #expect(fixture.provider.requestCount == 0)
        await fixture.submit("popraw adres na Krótka 8C, Inna Wieś")
        #expect(queries.last == "Krótka 8C, Inna Wieś")
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test func networkRetryUsesSavedFullQueryButExpiredOrCancelledDraftCannotRestartSearch() async throws {
        var queries: [String] = []
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
            queries.append(query)
            if queries.count == 1 { throw URLError(.notConnectedToInternet) }
            return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        await fixture.submit("Prowadź do Nowa Wieś 24 A")
        #expect(fixture.assistant.lastSearchQuery == "Nowa Wieś 24A")
        await fixture.submit("spróbuj ponownie")
        #expect(queries == ["Nowa Wieś 24A", "Nowa Wieś 24A"])
        fixture.session.state.destination = Destination(name: "Inny cel", coordinate: .init(latitude: 52.1, longitude: 21))
        await fixture.submit("numer domu 26B")
        #expect(queries.count == 2)
        #expect(fixture.assistant.destinationDialog == nil)
        await fixture.submit("Prowadź do Nowa Wieś 24A")
        await fixture.submit("anuluj")
        await fixture.submit("Nowa Wieś")
        #expect(queries.count == 3)
        #expect(fixture.provider.requestCount == 0)
    }

    @Test func initialLocalityAndSpokenNumberCanBeCorrectedWithoutAppendingConflictingTowns() async throws {
        var queries: [String] = []
        let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
            queries.append(query); return []
        })
        let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
        defer { fixture.close() }
        await fixture.submit("Prowadź do Długa 24A, Nowa Wieś")
        await fixture.submit("nie")
        await fixture.submit("Stara Wieś")
        await fixture.submit("dwa")
        #expect(queries.last == "Długa 2, Stara Wieś")
        await fixture.submit("numer 3")
        #expect(queries.last == "Długa 3, Stara Wieś")
        #expect(fixture.provider.requestCount == 0)
    }

    @Test func routingFailureAndCompletedRouteRetainOnlyAnExplicitCorrectionDraft() async throws {
        for fails in [true, false] {
            var queries: [String] = []
            let result = voiceAddressResult(number: "24A", city: "Nowa Wieś")
            let resolver = VoiceDestinationResolver(contacts: { _, _ in .noMatch }, places: { query, _ in
                queries.append(query)
                return query == "Długa 24A, Nowa Wieś" ? [result] : []
            })
            let fixture = try SavedVoiceFixture(places: [], destinationResolver: resolver)
            defer { fixture.close() }
            fixture.provider.fails = fails
            await fixture.submit("Prowadź do Długa 24A, Nowa Wieś")
            #expect(fixture.provider.requestCount == 1)
            #expect(fixture.replies.contains { $0.hasPrefix("Prowadzę do ") } == !fails)
            #expect(!fixture.assistant.canConfirm)
            if !fails { fixture.assistant.close() }
            await fixture.submit("numer domu 26B")
            #expect(queries.last == "Długa 26B, Nowa Wieś")
            #expect(fixture.provider.requestCount == 1)
        }
    }

    private func voiceAddressResult(number: String, city: String) -> SearchResult {
        SearchResult(destination: Destination(name: "Długa \(number)",
            coordinate: .init(latitude: 52.02, longitude: 21), address: "Długa \(number), \(city)"),
            street: "Długa", houseNumber: number, city: city, countryCode: "pl", isPOI: false)
    }
}
#endif
