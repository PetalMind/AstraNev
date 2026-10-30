#if os(iOS)
import Foundation
import Observation

/// Owns the search request and its results; the editor continues to own the draft.
@MainActor @Observable
final class IOSTripPlaceSearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case places, stops
        var id: Self { self }
        var title: String { self == .places ? "Adresy i miejsca" : "Przystanki" }
    }

    struct Request: Equatable {
        let query: String
        let scope: Scope
        let revision: Int
    }

    private(set) var results: [SearchResult] = []
    private(set) var stops: [TransitStop] = []
    private(set) var loading = false
    private(set) var completed = false
    private(set) var errorMessage: String?
    private(set) var resultsRequest: Request?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var lastRequest: Request?
    @ObservationIgnored private var resultIdentities = SearchResultIdentityRegistry()

    static func localMatches(query: String, destinations: [Destination]) -> [Destination] {
        let words = normalized(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { return [] }
        var matches: [Destination] = []
        for place in destinations {
            let text = normalized(place.name + " " + (place.address ?? ""))
            if words.allSatisfy({ text.contains($0) }),
               !matches.contains(where: { samePlace($0, place) }) {
                matches.append(place)
            }
            if matches.count == 6 { break }
        }
        return matches
    }

    static func samePlace(_ lhs: Destination, _ rhs: Destination) -> Bool {
        lhs.coordinate.distance(to: rhs.coordinate) < 5
            && SearchRanking.normalizedIdentity(lhs.name) == SearchRanking.normalizedIdentity(rhs.name)
    }

    func search(_ request: Request, context: SearchContext, transitSearchCenter: Coordinate?,
                transitProvider: any TransitDataProviding) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        let isSubmission = request.revision > (lastRequest?.revision ?? 0)
        lastRequest = request
        if !canKeepResults(for: request) { clearResults() }
        completed = false
        errorMessage = nil
        loading = false
        guard request.query.count >= 2 else { return }
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            if !isSubmission { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            if request.scope == .stops {
                // Transit searches follow the selected map area when the draft has no origin.
                let found = await transitProvider.search(request.query, near: transitSearchCenter)
                guard !Task.isCancelled, requestID == id else { return }
                stops = found.stops
                resultsRequest = request
            } else {
                let endpoint = URL(string: UserDefaults.standard.string(forKey: "routingServer") ?? "")
                    ?? URL(string: "https://valhalla1.openstreetmap.de")!
                let found = try await SearchEngine(matrix: ValhallaRouteProvider(endpoint: endpoint)).search(request.query,
                    context: context, includeUUGFallback: isSubmission,
                    onUpdate: { [weak self] partial in
                        guard let self, !Task.isCancelled, self.requestID == id else { return }
                        self.results = self.resultIdentities.stabilize(partial)
                        self.resultsRequest = request
                    })
                guard !Task.isCancelled, requestID == id else { return }
                results = resultIdentities.stabilize(found)
                resultsRequest = request
            }
            completed = true
        } catch is CancellationError {
            // A replacement request may keep this snapshot; the view disables it
            // until resultsRequest matches, and cancel() clears it on dismissal.
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            if resultsRequest != request { clearResults() }
            switch SearchError.classify(error) {
            case .offline: errorMessage = "Brak internetu. Możesz wybrać zapisane miejsce lub punkt na mapie."
            case .timeout: errorMessage = "Wyszukiwanie trwa zbyt długo. Spróbuj ponownie lub wybierz punkt na mapie."
            case .locationRequired: errorMessage = "Dopisz miejscowość albo ustaw obszar na mapie."
            default: errorMessage = "Nie udało się wyszukać adresu. Spróbuj ponownie lub wybierz punkt na mapie."
            }
        }
    }

    func cancel() {
        requestID = UUID()
        clearResults()
        loading = false
        completed = false
        errorMessage = nil
    }

    private func canKeepResults(for request: Request) -> Bool {
        guard request.query.count >= 2, let previous = resultsRequest,
              previous.scope == request.scope else { return false }
        let currentQuery = Self.normalized(request.query)
        let previousQuery = Self.normalized(previous.query)
        return currentQuery.hasPrefix(previousQuery) || previousQuery.hasPrefix(currentQuery)
    }

    private func clearResults() {
        results = []
        stops = []
        resultsRequest = nil
        resultIdentities = SearchResultIdentityRegistry()
    }

    private static func normalized(_ value: String) -> String {
        QueryClassifier.normalize(value)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
#endif
