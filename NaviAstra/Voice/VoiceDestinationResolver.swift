#if os(iOS)
import Foundation

/// Keeps a matching contact out of public place searches, and preserves
/// ambiguity before any destination is allowed to change navigation.
@MainActor
struct VoiceDestinationResolver {
    typealias ContactsLookup = @MainActor (String, Coordinate?) async throws -> VoiceContactResolution
    typealias PlacesLookup = @MainActor (String, SearchContext) async throws -> [SearchResult]

    var contacts: ContactsLookup = { query, origin in
        try await ContactsSearchProvider().resolveVoiceDestination(query, near: origin)
    }
    var places: PlacesLookup = { query, context in
        let address = UserDefaults.standard.string(forKey: "routingServer") ?? ""
        let endpoint = URL(string: address) ?? URL(string: "https://valhalla1.openstreetmap.de")!
        return try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint))
            .search(query, context: context, includeUUGFallback: true, includeContacts: false)
    }

    func resolve(_ query: String, context: SearchContext,
                 currentOrigin: Coordinate?) async throws -> VoiceDestinationSelection.Outcome {
        // Treat speech as a submitted whole address, including a separated or
        // spoken building suffix, before selecting providers or matching results.
        let query = VoiceAddressQuery.normalized(query)
        let intent = QueryClassifier().classify(query)
        if intent.intent == .place || intent.intent == .unknown {
            let contact = try await contacts(query, context.origin)
            try Task.checkCancellation()
            switch contact {
            case .resolved(let result): return .direct(result)
            case .ambiguous(let results, _, _):
                guard results.count > 1 else {
                    return .unavailable("Ten kontakt pasuje do kilku osób lub adresów. Podaj pełne imię i nazwisko i dopisz „dom” albo „praca”.")
                }
                return .choices(results)
            case .unavailable(let reason):
                if reason != .accessNotGranted { return .unavailable(reason.message) }
            case .noMatch: break
            }
        }
        if (intent.intent == .brand || intent.intent == .category),
           intent.parcelQuery?.reference == nil, currentOrigin == nil {
            return .unavailable("Czekam na aktualną lokalizację, żeby wybrać najbliższe miejsce. Włącz lokalizację i powtórz polecenie.")
        }
        let results = try await places(query, context)
        try Task.checkCancellation()
        return VoiceDestinationSelection.resolve(results, query: query, origin: currentOrigin)
    }
}
#endif
