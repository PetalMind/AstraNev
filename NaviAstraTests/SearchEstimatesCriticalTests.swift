import Foundation
import Testing
@testable import NaviAstra

/// Routing estimates decide which branch is useful; missing data must stay unknown.
@MainActor struct SearchEstimatesCriticalTests {
    private let origin = Coordinate(latitude: 52, longitude: 21)

    private func result(_ index: Int, name: String = "Lidl", straight: Double,
                        time: Double? = nil) -> SearchResult {
        SearchResult(destination: Destination(name: name,
            coordinate: Coordinate(latitude: 52 + Double(index) * 0.001, longitude: 21)),
            street: nil, houseNumber: nil, city: "Warszawa", countryCode: "pl",
            isPOI: true, category: "supermarket", brand: "Lidl", straightDistance: straight,
            travelTime: time, travelDistance: time == nil ? nil : straight * 2,
            travelEstimateStatus: time == nil ? .calculating : .notRequested,
            requiresRouteEstimate: true)
    }

    @Test func actualJourneyTimeOutranksStraightDistanceWithinBrandAndCategory() {
        let nearSlow = result(1, straight: 200, time: 900)
        let fartherFast = result(2, name: "Lidl — supermarket", straight: 2_000, time: 180)
        let context = SearchContext(origin: origin)
        for intent in [ClassifiedQuery(intent: .brand, text: "Lidl"),
                       ClassifiedQuery(intent: .category, text: "supermarket", photonTag: "shop:supermarket")] {
            var swappedNear = nearSlow; swappedNear.straightDistance = 20_000
            var swappedFar = fartherFast; swappedFar.straightDistance = 5
            #expect(SearchRanking.precedes(nearSlow, fartherFast, intent: intent, context: context)
                == SearchRanking.precedes(swappedNear, swappedFar, intent: intent, context: context))
            #expect(SearchRanking.precedes(fartherFast, nearSlow,
                intent: intent, context: context, withTravelEstimates: true))
            #expect(!SearchRanking.precedes(nearSlow, fartherFast,
                intent: intent, context: context, withTravelEstimates: true))
        }
        var scoped = ClassifiedQuery(intent: .brand, text: "Lidl", location: "Mokotowska")
        var streetMatch = nearSlow
        streetMatch.street = "Mokotowska"
        #expect(SearchRanking.precedes(streetMatch, fartherFast,
            intent: scoped, context: context, withTravelEstimates: true))
        scoped.location = nil
        #expect(SearchRanking.precedes(fartherFast, streetMatch,
            intent: scoped, context: context, withTravelEstimates: true))
    }

    @Test func missingAndInvalidEstimatesNeverLookFasterOrCrashSummaryFormatting() {
        let known = result(3, straight: 3_000, time: 400)
        let context = SearchContext(origin: origin)
        let intent = ClassifiedQuery(intent: .brand, text: "Lidl")
        for value in [Double.nan, .infinity, -.infinity, -10] {
            var invalid = result(1, straight: 100, time: value)
            invalid.travelEstimateStatus = .unavailable
            #expect(SearchRanking.precedes(known, invalid,
                intent: intent, context: context, withTravelEstimates: true))
            #expect(!SearchRanking.precedes(invalid, known,
                intent: intent, context: context, withTravelEstimates: true))
            #expect(invalid.travelSummary?.contains("niedostępn") == true)
        }
        let missing = result(1, straight: 100)
        #expect(SearchRanking.precedes(known, missing,
            intent: intent, context: context, withTravelEstimates: true))
        var along = intent
        along.alongRoute = true
        var measuredDetour = known
        measuredDetour.detour = 120
        var invalidDetour = missing
        invalidDetour.detour = .nan
        #expect(SearchRanking.precedes(measuredDetour, invalidDetour,
            intent: along, context: context, withTravelEstimates: true))
        #expect(!SearchRanking.precedes(invalidDetour, measuredDetour,
            intent: along, context: context, withTravelEstimates: true))
    }
    @Test func geometricOffsetsNeverBecomePublicDistanceOrNearestOrder() {
        var farther = result(1, straight: 9_000)
        farther.destination.address = "Alfa 1, Warszawa"
        var closer = result(2, straight: 50)
        closer.destination.address = "Zeta 1, Warszawa"
        let intent = ClassifiedQuery(intent: .brand, text: "Lidl")
        let context = SearchContext(origin: origin)
        for estimated in [false, true] {
            #expect(SearchRanking.precedes(farther, closer, intent: intent, context: context,
                withTravelEstimates: estimated))
        }
        closer.detourDistance = 123
        #expect(closer.travelSummary?.contains("123") == false)
        #expect(closer.travelSummary?.contains("0,1") == false)
        closer.travelEstimateStatus = .unavailable
        #expect(closer.travelSummary?.contains("niedostępn") == true)
        closer.travelDistance = 1_200
        #expect(closer.travelSummary?.contains("1,2 km trasą") == true)
    }

    @MainActor private final class EstimateGate {
        var calls: [[SearchResult]] = []
        var waiting: CheckedContinuation<[String: ProgressiveSearchEstimates.Estimate], Error>?

        func resolve(_ targets: [SearchResult]) async throws -> [String: ProgressiveSearchEstimates.Estimate] {
            calls.append(targets)
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }

        func finish(_ values: [String: ProgressiveSearchEstimates.Estimate]) {
            let pending = waiting
            waiting = nil
            pending?.resume(returning: values)
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Progressive search did not reach the expected state within two seconds")
    }

    @Test func firstETADoesNotWaitForLateProviderAndSurvivesMetadataUpdates() async throws {
        let first = result(1, straight: 200)
        let later = result(2, straight: 2_000)
        var updates: [[SearchResult]] = []
        var targetsByCall: [[String]] = []
        let search = ProgressiveSearchEstimates(intent: ClassifiedQuery(intent: .brand, text: "Lidl"),
            context: SearchContext(origin: origin), resolver: { targets in
                targetsByCall.append(targets.map { $0.placeIdentity.cacheKey })
                return Dictionary(uniqueKeysWithValues: targets.map {
                    ($0.placeIdentity.cacheKey, .init(time: $0.id == first.id ? 900 : 180, distance: 2_000))
                })
            }, onUpdate: { updates.append($0) })
        defer { search.cancel() }
        search.publish([first])
        #expect(updates.count == 1)
        #expect(updates.last?.first?.travelTime == nil)
        try await waitUntil { updates.last?.first?.travelTime == 900 }
        // No final provider reply or complete() call has happened yet.
        #expect(targetsByCall == [[first.placeIdentity.cacheKey]])
        var enrichedMetadata = first
        enrichedMetadata.destination.id = UUID()
        enrichedMetadata.website = "https://example.invalid/sklep"
        search.publish([enrichedMetadata, later])
        #expect(updates.last?.first { $0.placeIdentity.cacheKey == first.placeIdentity.cacheKey }?.travelTime == 900)
        let final = await search.complete([enrichedMetadata, later])
        #expect(targetsByCall == [[first.placeIdentity.cacheKey], [later.placeIdentity.cacheKey]])
        #expect(final.first?.id == later.id)
        #expect(final.first?.travelTime == 180)
        #expect(final.first { $0.placeIdentity.cacheKey == first.placeIdentity.cacheKey }?.website == enrichedMetadata.website)
    }

    @Test func unchangedTargetsUseOneBatchAndInflightRowsRemainCalculating() async throws {
        let first = result(1, straight: 200)
        let next = result(2, straight: 2_000)
        let gate = EstimateGate()
        var updates: [[SearchResult]] = []
        let search = ProgressiveSearchEstimates(intent: ClassifiedQuery(intent: .brand, text: "Lidl"),
            context: SearchContext(origin: origin), resolver: { try await gate.resolve($0) },
            onUpdate: { updates.append($0) })
        defer { search.cancel() }
        for _ in 0..<5 { search.publish([first]) }
        try await waitUntil { gate.calls.count == 1 }
        search.publish([first, next])
        #expect(gate.calls.count == 1)
        #expect(updates.last?.first { $0.id == first.id }?.travelEstimateStatus == .calculating)
        gate.finish([first.placeIdentity.cacheKey: .init(time: 900, distance: 2_000)])
        try await waitUntil { gate.calls.count == 2 }
        #expect(gate.calls[0].map(\.id) == [first.id])
        #expect(gate.calls[1].map(\.id) == [next.id])
        gate.finish([next.placeIdentity.cacheKey: .init(time: 180, distance: 2_500)])
        let final = await search.complete([first, next])
        #expect(final.first?.id == next.id)
        for _ in 0..<5 { search.publish([first, next]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.calls.count == 2)
    }

    @Test func cancelledSearchAndCancelledCompletionCannotPublishLateMatrixResults() async throws {
        let first = result(1, straight: 200)
        for cancelCompletion in [false, true] {
            let gate = EstimateGate()
            var updates: [[SearchResult]] = []
            let search = ProgressiveSearchEstimates(intent: ClassifiedQuery(intent: .brand, text: "Lidl"),
                context: SearchContext(origin: origin), resolver: { try await gate.resolve($0) },
                onUpdate: { updates.append($0) })
            let completion = Task { @MainActor in await search.complete([first]) }
            try await waitUntil { gate.calls.count == 1 }
            let countBeforeCancellation = updates.count
            if cancelCompletion { completion.cancel() } else { search.cancel() }
            await Task.yield()
            gate.finish([first.placeIdentity.cacheKey: .init(time: 120, distance: 1_000)])
            _ = await completion.value
            try await Task.sleep(for: .milliseconds(20))
            #expect(updates.count == countBeforeCancellation)
            #expect(!updates.contains { $0.contains { $0.travelTime == 120 } })
            search.publish([result(2, straight: 100)])
            #expect(updates.count == countBeforeCancellation)
            search.cancel()
        }
    }

    @Test func invalidMatrixCellsRemainUnavailableWithoutFallbackRequestFanout() async throws {
        let candidates = (1...4).map { result($0, straight: Double($0) * 100) }
        var calls = 0
        let invalidTimes = [Double.nan, .infinity, -10, 120]
        let search = ProgressiveSearchEstimates(intent: ClassifiedQuery(intent: .brand, text: "Lidl"),
            context: SearchContext(origin: origin), resolver: { targets in
                calls += 1
                return Dictionary(uniqueKeysWithValues: targets.enumerated().map { index, result in
                    (result.placeIdentity.cacheKey, .init(time: invalidTimes[index], distance: index == 3 ? -1 : 1_000))
                })
            }, onUpdate: { _ in })
        defer { search.cancel() }
        let final = await search.complete(candidates)
        #expect(calls == 1)
        #expect(final.count == candidates.count)
        #expect(final.allSatisfy { $0.travelTime == nil && $0.travelDistance == nil && $0.travelEstimateStatus == .unavailable })
        _ = await search.complete(candidates)
        #expect(calls == 1)
    }

}
