import Foundation
import Testing
@testable import NaviAstra

/// A retry must never replace a good routed estimate or update another search.
@MainActor struct SearchTravelRecoveryCriticalTests {
    private func result() -> SearchResult {
        SearchResult(destination: Destination(name: "Biblioteka",
            coordinate: Coordinate(latitude: 52.23, longitude: 21.01)),
            street: "Marszałkowska", houseNumber: "10", city: "Warszawa", countryCode: "pl",
            isPOI: true, category: "library", travelEstimateStatus: .unavailable,
            requiresRouteEstimate: true)
    }

    private func store(with result: SearchResult) -> SearchStore {
        // Construction only: these tests never call a transit or network method.
        let store = SearchStore(transitRepository: LocalTransitDataProvider())
        _ = store.beginRequest()
        store.publishResults([result])
        return store
    }

    @MainActor private final class EstimateGate {
        var destinations: [Destination] = []
        var returned = 0
        private var continuation: CheckedContinuation<SearchRouteEstimate?, Never>?

        func resolve(_ destination: Destination) async throws -> SearchRouteEstimate? {
            destinations.append(destination)
            let estimate = await withCheckedContinuation { continuation = $0 }
            returned += 1
            return estimate
        }

        func finish(_ estimate: SearchRouteEstimate?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: estimate)
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Odzyskiwanie dojazdu nie osiągnęło oczekiwanego stanu w ciągu dwóch sekund.")
    }

    @Test func repeatedTapsCoalesceAndPendingRecoverySurvivesMetadataUpdates() async throws {
        let item = result()
        let store = store(with: item)
        let gate = EstimateGate()
        var updates = 0
        for _ in 0..<5 {
            store.retryTravelEstimate(for: item, estimator: { try await gate.resolve($0) },
                                      onUpdate: { _ in updates += 1 })
        }
        #expect(store.results.first?.travelEstimateStatus == .calculating)
        try await waitUntil { gate.destinations.count == 1 }
        #expect(updates == 1)
        var metadata = item
        metadata.destination.id = UUID()
        metadata.website = "https://example.invalid/biblioteka"
        store.publishResults([metadata])
        #expect(store.results.first?.id == item.id)
        #expect(store.results.first?.travelEstimateStatus == .calculating)
        gate.finish(.init(travelTime: 420, distanceMeters: 2_100))
        try await waitUntil { store.results.first?.travelTime == 420 }
        #expect(gate.destinations.count == 1)
        #expect(updates == 2)
        #expect(store.travelRecoveryMessages.isEmpty)
    }

    @Test func recoveredMetricsSurviveLatePartialWithNewProviderIdentity() async throws {
        let item = result()
        let store = store(with: item)
        store.retryTravelEstimate(for: item, estimator: { _ in
            .init(travelTime: 420, distanceMeters: 2_100)
        }, onUpdate: { _ in })
        try await waitUntil { store.results.first?.travelTime == 420 }
        var metadata = item
        metadata.destination.id = UUID()
        metadata.website = "https://example.invalid/aktualne-dane"
        store.publishResults([metadata])
        #expect(store.results.first?.id == item.id)
        #expect(store.results.first?.website == metadata.website)
        #expect(store.results.first?.travelTime == 420)
        #expect(store.results.first?.travelDistance == 2_100)
        #expect(store.results.first?.travelEstimateStatus == .notRequested)
        #expect(store.travelRecoveryMessages.isEmpty)
    }

    @Test func recoveredFasterJourneyMovesAheadAndKeepsRankAfterLateMetadata() async throws {
        let quick = result()
        var slow = result()
        slow.destination.coordinate = Coordinate(latitude: 52.25, longitude: 21.02)
        slow.travelTime = 1_200
        slow.travelDistance = 6_000
        slow.travelEstimateStatus = .notRequested
        let store = store(with: slow)
        store.configureEstimateRanking(query: "Biblioteka",
            context: SearchContext(origin: Coordinate(latitude: 52.22, longitude: 21)))
        store.publishResults([slow, quick])
        #expect(store.results.first?.id == slow.id)
        var lastPublishedFirstID: UUID?
        store.retryTravelEstimate(for: quick, estimator: { _ in
            .init(travelTime: 120, distanceMeters: 900)
        }, onUpdate: { lastPublishedFirstID = $0.first?.id })
        try await waitUntil { store.results.first?.id == quick.id }
        #expect(lastPublishedFirstID == quick.id)
        var lateMetadata = quick
        lateMetadata.destination.id = UUID()
        lateMetadata.website = "https://example.invalid/godziny"
        store.publishResults([slow, lateMetadata])
        #expect(store.results.first?.id == quick.id)
        #expect(store.results.first?.travelTime == 120)
        #expect(store.results.first?.website == lateMetadata.website)
    }

    @Test func failedManualRecoveryDoesNotOverrideValidLateMatrix() async throws {
        let item = result()
        let store = store(with: item)
        let gate = EstimateGate()
        store.retryTravelEstimate(for: item, estimator: { try await gate.resolve($0) }, onUpdate: { _ in })
        try await waitUntil { gate.destinations.count == 1 }
        var matrix = item
        matrix.travelTime = 300
        matrix.travelDistance = 1_800
        matrix.travelEstimateStatus = .notRequested
        store.publishResults([matrix])
        gate.finish(nil)
        try await waitUntil { gate.returned == 1 }
        #expect(store.results.first?.travelTime == 300)
        #expect(store.results.first?.travelDistance == 1_800)
        #expect(store.travelRecoveryMessages.isEmpty)
        store.publishResults([item])
        #expect(store.results.first?.travelTime == 300)
        #expect(store.results.first?.travelEstimateStatus == .notRequested)
    }

    @Test func queryChangeDismissalAndSelectionRejectCancelledLateCallback() async throws {
        for cancellation in 0..<3 {
            let item = result()
            let store = store(with: item)
            let gate = EstimateGate()
            var updates = 0
            store.retryTravelEstimate(for: item, estimator: { try await gate.resolve($0) },
                                      onUpdate: { _ in updates += 1 })
            try await waitUntil { gate.destinations.count == 1 }
            switch cancellation {
            case 0: _ = store.beginRequest(preservingResults: true)
            case 1: store.cancelSearches()
            default: store.cancelPlaceSearch()
            }
            #expect(store.results.first?.travelEstimateStatus == .unavailable)
            // Even the same place in a later list must not inherit the old request.
            store.publishResults([item])
            let countAfterCancellation = updates
            gate.finish(.init(travelTime: 999, distanceMeters: 9_999))
            try await waitUntil { gate.returned == 1 }
            #expect(updates == countAfterCancellation)
            #expect(store.results.first?.travelTime == nil)
            #expect(store.results.first?.travelDistance == nil)
            #expect(store.travelRecoveryMessages.isEmpty)
        }
    }

    @Test func staleAbsentAndAlreadyResolvedResultsCannotStartRecovery() async throws {
        let item = result()
        let store = store(with: item)
        var calls = 0
        let estimator: @MainActor (Destination) async throws -> SearchRouteEstimate? = { _ in
            calls += 1
            return nil
        }
        _ = store.beginRequest(preservingResults: true)
        store.retryTravelEstimate(for: item, estimator: estimator, onUpdate: { _ in })
        store.publishResults([])
        store.retryTravelEstimate(for: item, estimator: estimator, onUpdate: { _ in })
        var resolved = item
        resolved.travelTime = 300
        resolved.travelDistance = 1_800
        store.publishResults([resolved])
        store.retryTravelEstimate(for: item, estimator: estimator, onUpdate: { _ in })
        await Task.yield()
        #expect(calls == 0)
        #expect(store.results.first?.travelTime == 300)
    }

    @Test func invalidRecoveryStaysUnknownAndCanBeRetriedWithoutPoisoningMatrix() async throws {
        var item = result()
        item.travelTime = .infinity
        item.travelDistance = 1_000
        let store = store(with: item)
        store.retryTravelEstimate(for: item, estimator: { _ in
            .init(travelTime: .nan, distanceMeters: 1_000)
        }, onUpdate: { _ in })
        try await waitUntil { store.travelRecoveryMessages[item.id] != nil }
        #expect(store.results.first?.travelTime == nil)
        #expect(store.results.first?.travelDistance == 1_000)
        #expect(store.results.first?.travelEstimateStatus == .unavailable)
        #expect(store.travelRecoveryMessages[item.id]
            == "Spróbuj ponownie lub wybierz miejsce, aby zaplanować trasę.")
        let gate = EstimateGate()
        store.retryTravelEstimate(for: item, estimator: { try await gate.resolve($0) }, onUpdate: { _ in })
        #expect(store.travelRecoveryMessages.isEmpty)
        try await waitUntil { gate.destinations.count == 1 }
        gate.finish(.init(travelTime: 180, distanceMeters: 900))
        try await waitUntil { store.results.first?.travelTime == 180 }
        #expect(store.results.first?.travelDistance == 900)
        #expect(store.travelRecoveryMessages.isEmpty)
    }
}
