#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

/// Geographic scope must contain generic place searches before relevance or ETA can rank them.
@MainActor struct SearchLocalityCriticalTests {
    private let origin = Coordinate(latitude: 52.2297, longitude: 21.0122)
    private let krakow = Coordinate(latitude: 50.0647, longitude: 19.9450)

    private func place(_ name: String, northMeters: Double, from center: Coordinate? = nil,
                       category: String? = "fuel", time: Double? = nil) -> SearchResult {
        let center = center ?? origin
        return SearchResult(destination: Destination(name: name,
            coordinate: Coordinate(latitude: center.latitude + northMeters / 111_195,
                                   longitude: center.longitude)),
            street: nil, houseNumber: nil, city: nil, countryCode: "pl",
            isPOI: true, category: category, travelTime: time,
            travelDistance: time == nil ? nil : northMeters * 1.5)
    }

    @Test func polishFuelAliasesAndNearbyPhrasesKeepTheFuelCategory() {
        for query in ["stacja benzynowa", "stacje benzynowe", "stacji benzynowej",
                      "stację benzynową", "STACJA BENZYNOWA", "stacja paliw",
                      "stacje paliw", "paliwo", "stacja benzynowa w pobliżu",
                      "najbliższa stacja benzynowa"] {
            let intent = QueryClassifier().classify(query)
            #expect(intent.intent == .category)
            #expect(intent.photonTag == "amenity:fuel")
            #expect(intent.filter == "[amenity=fuel]")
            #expect(intent.location == nil)
        }
        let pharmacy = QueryClassifier().classify("najbliższa apteka")
        #expect(pharmacy.intent == .category)
        #expect(pharmacy.photonTag == "amenity:pharmacy")
        let brand = QueryClassifier().classify("najbliższy Orlen")
        #expect(brand.intent == .brand)
        #expect(brand.text == "orlen")
        let address = QueryClassifier().classify("Najbliższa 12, Kraków")
        #expect(address.intent == .address)
        #expect(address.text == "najblizsza 12, krakow")
        let cityAndRoute = QueryClassifier().classify("stacja benzynowa w Krakowie po trasie")
        #expect(cityAndRoute.photonTag == "amenity:fuel")
        #expect(cityAndRoute.location == "krakowie")
        #expect(cityAndRoute.alongRoute)
    }

    @Test func localOrlenSurvivesADistantExactNameWithATwoHourRouteEstimate() {
        let local = place("ORLEN", northMeters: 1_000)
        let distant = place("Stacja benzynowa", northMeters: 140_000, time: 7_920)
        let intent = QueryClassifier().classify("stacja benzynowa")
        let context = SearchContext(origin: origin)
        for allowsExpansion in [false, true] {
            let results = SearchDeduplicator.mergeAndRank([distant, local], intent: intent,
                context: context, searchCenter: origin, routeOrigin: origin,
                allowsExpansion: allowsExpansion)
            #expect(results.map(\.id) == [local.id])
            #expect(results.first?.travelTime == nil)
            #expect(results.first?.travelDistance == nil)
        }
    }

    @Test func partialCategoriesStayLocalAndFinalResultsUseOnlyTheFirstPopulatedArea() {
        let local = place("ORLEN", northMeters: 1_000)
        let wider = place("Shell", northMeters: 7_000)
        let outer = place("BP", northMeters: 16_000)
        let outside = place("Stacja benzynowa", northMeters: 25_000)
        let intent = QueryClassifier().classify("stacja benzynowa")
        let context = SearchContext(origin: origin)
        let candidates = [outside, outer, wider]
        let partial = SearchDeduplicator.mergeAndRank(candidates, intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin, allowsExpansion: false)
        #expect(partial.isEmpty)
        let expanded = SearchDeduplicator.mergeAndRank(candidates, intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(expanded.map(\.id) == [wider.id])
        let withLocal = SearchDeduplicator.mergeAndRank(candidates + [local], intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(withLocal.map(\.id) == [local.id])
        let outerOnly = SearchDeduplicator.mergeAndRank([outer, outside], intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(outerOnly.map(\.id) == [outer.id])
        let outsideOnly = SearchDeduplicator.mergeAndRank([outside], intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(outsideOnly.isEmpty)
    }

    @Test func brandExpansionDoesNotMixNearbyBranchesWithDistantOnes() {
        let local = place("ORLEN", northMeters: 4_000)
        let wider = place("ORLEN", northMeters: 12_000)
        let outer = place("ORLEN", northMeters: 24_000)
        let outside = place("ORLEN", northMeters: 35_000)
        let intent = QueryClassifier().classify("Orlen")
        let context = SearchContext(origin: origin)
        let partial = SearchGeographicScope.filter([wider, outer], intent: intent,
            context: context, searchCenter: origin, allowsExpansion: false)
        #expect(partial.isEmpty)
        let cases: [([SearchResult], [UUID])] = [
            ([local, wider, outer], [local.id]), ([wider, outer], [wider.id]),
            ([outer, outside], [outer.id]), ([outside], [])
        ]
        for (candidates, expected) in cases {
            let results = SearchDeduplicator.mergeAndRank(candidates, intent: intent,
                context: context, searchCenter: origin, routeOrigin: origin)
            #expect(results.map(\.id) == expected)
        }
    }

    @Test func explicitCityKeepsResultsFarFromGPSAndTheCurrentMapArea() {
        let inKrakow = place("ORLEN", northMeters: 1_000, from: krakow)
        let nearGPS = place("Stacja benzynowa", northMeters: 1_000)
        let intent = QueryClassifier().classify("stacja benzynowa w Krakowie")
        let context = SearchContext(origin: origin, area: origin)
        for allowsExpansion in [false, true] {
            let results = SearchDeduplicator.mergeAndRank([nearGPS, inKrakow], intent: intent,
                context: context, searchCenter: krakow, routeOrigin: origin,
                allowsExpansion: allowsExpansion)
            #expect(results.map(\.id) == [inKrakow.id])
        }
        let unresolvedCity = SearchDeduplicator.mergeAndRank([nearGPS], intent: intent,
            context: context, searchCenter: nil, routeOrigin: origin)
        #expect(unresolvedCity.isEmpty)
    }

    @Test func selectedMapAreaOverridesGPSForGenericCategories() {
        let inArea = place("ORLEN", northMeters: 1_000, from: krakow)
        let nearGPS = place("Stacja benzynowa", northMeters: 1_000)
        let context = SearchContext(origin: origin, area: krakow)
        let results = SearchDeduplicator.mergeAndRank([nearGPS, inArea],
            intent: QueryClassifier().classify("stacja benzynowa"), context: context,
            searchCenter: origin, routeOrigin: origin)
        #expect(results.map(\.id) == [inArea.id])
    }

    @Test func addressesCoordinatesNamedPlacesAndExactParcelCodesRemainSearchableFarAway() {
        let destination = place("Miejsce docelowe", northMeters: 140_000, category: nil)
        var locker = place("Paczkomat InPost WAW01M", northMeters: 140_000, category: "parcel_locker")
        locker.parcelReferences = ["WAW01M"]
        let cases: [(ClassifiedQuery, SearchResult)] = [
            (ClassifiedQuery(intent: .address, text: "Długa 12, Kraków"), destination),
            (ClassifiedQuery(intent: .place, text: "Wawel"), destination),
            (ClassifiedQuery(intent: .coordinates, text: "50.0647, 19.9450", coordinate: krakow), destination),
            (QueryClassifier().classify("WAW01M"), locker)
        ]
        for (intent, candidate) in cases {
            #expect(SearchGeographicScope.radii(for: intent).isEmpty)
            for allowsExpansion in [false, true] {
                let results = SearchDeduplicator.mergeAndRank([candidate], intent: intent,
                    context: SearchContext(origin: origin), searchCenter: origin,
                    routeOrigin: origin, allowsExpansion: allowsExpansion)
                #expect(results.map(\.id) == [candidate.id])
            }
        }
    }

    @Test func alongRouteUsesTheRouteCorridorBeyondTheNearbySearchArea() {
        let onRoute = place("ORLEN", northMeters: 60_000)
        var offRoute = place("Stacja benzynowa", northMeters: 60_000)
        offRoute.destination.coordinate.longitude += 0.15
        let target = place("Cel", northMeters: 100_000).destination.coordinate
        let context = SearchContext(origin: origin, route: [origin, target], routeTarget: target)
        let intent = QueryClassifier().classify("stacja benzynowa po trasie")
        #expect(SearchGeographicScope.radii(for: intent).isEmpty)
        for allowsExpansion in [false, true] {
            let results = SearchDeduplicator.mergeAndRank([offRoute, onRoute], intent: intent,
                context: context, searchCenter: origin, routeOrigin: origin,
                allowsExpansion: allowsExpansion)
            #expect(results.map(\.id) == [onRoute.id])
        }
    }

    @Test func actualRoadTimeStillRanksBranchesInsideTheLocalArea() {
        let nearSlow = place("Stacja benzynowa", northMeters: 200, time: 1_200)
        let fartherFast = place("ORLEN", northMeters: 2_000, time: 180)
        let intent = QueryClassifier().classify("stacja benzynowa")
        let context = SearchContext(origin: origin)
        let scoped = SearchDeduplicator.mergeAndRank([nearSlow, fartherFast], intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(Set(scoped.map(\.id)) == Set([nearSlow.id, fartherFast.id]))
        let ranked = scoped.sorted {
            SearchRanking.precedes($0, $1, intent: intent, context: context, withTravelEstimates: true)
        }
        #expect(ranked.map(\.id) == [fartherFast.id, nearSlow.id])
        #expect(ranked.first?.travelTime == 180)
        #expect(ranked.first?.travelDistance == fartherFast.travelDistance)
    }

    @Test func nearbyBrandsReachTheMatrixBeforeSixteenGenericCategoryNameMatches() {
        let nearest = place("ORLEN", northMeters: 200)
        let next = place("Shell", northMeters: 400)
        let named = (0..<20).map { place("Stacja benzynowa", northMeters: 1_000 + Double($0) * 70) }
        let intent = QueryClassifier().classify("stacja benzynowa")
        let context = SearchContext(origin: origin)
        let scoped = SearchDeduplicator.mergeAndRank(named + [next, nearest], intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        // This is the old cutoff: the closest brand would never receive an ETA.
        #expect(!scoped.prefix(16).contains { $0.id == nearest.id })
        var selected = SearchRanking.routeEstimateCandidates(scoped, intent: intent,
            context: context, searchCenter: origin, limit: 16)
        #expect(selected.count == 16)
        #expect(selected.prefix(2).map(\.id) == [nearest.id, next.id])
        #expect(selected.allSatisfy { $0.travelTime == nil && $0.travelDistance == nil })
        selected[0].travelTime = 600; selected[0].travelDistance = 2_000
        selected[1].travelTime = 180; selected[1].travelDistance = 1_000
        let routed = selected.sorted {
            SearchRanking.precedes($0, $1, intent: intent, context: context, withTravelEstimates: true)
        }
        #expect(routed.first?.id == next.id)
        #expect(routed.first?.travelTime == 180)
    }

    @Test func routingCandidateBudgetUsesTheRequestedCityOrMapAreaAndPreservesExactSearches() {
        let nearCity = place("ORLEN", northMeters: 200, from: krakow)
        let cityEdge = place("Stacja benzynowa", northMeters: 2_500, from: krakow)
        let nearGPS = place("Stacja benzynowa", northMeters: 100)
        let cases = [
            (QueryClassifier().classify("stacja benzynowa w Krakowie"), SearchContext(origin: origin)),
            (QueryClassifier().classify("stacja benzynowa"), SearchContext(origin: origin, area: krakow))
        ]
        for (intent, context) in cases {
            let scoped = SearchDeduplicator.mergeAndRank([nearGPS, cityEdge, nearCity], intent: intent,
                context: context, searchCenter: krakow, routeOrigin: origin)
            let selected = SearchRanking.routeEstimateCandidates(scoped, intent: intent,
                context: context, searchCenter: krakow, limit: 1)
            #expect(selected.map(\.id) == [nearCity.id])
            #expect(selected.first?.travelTime == nil)
        }
        for query in ["Długa 12, Kraków", "WAW01M", "stacja paliw po trasie"] {
            let selected = SearchRanking.routeEstimateCandidates([cityEdge, nearGPS],
                intent: QueryClassifier().classify(query), context: SearchContext(origin: origin),
                searchCenter: origin, limit: 1)
            #expect(selected.map(\.id) == [cityEdge.id])
        }
    }

    @Test func fuelNamesAndContactsCannotHideValidStationsInTheExpandedArea() {
        let bank = place("Stacja benzynowa", northMeters: 500, category: "bank")
        var unclassified = place("Stacja benzynowa", northMeters: 1_000, category: nil)
        unclassified.isPOI = false
        var contact = place("Stacja benzynowa", northMeters: 1_500)
        contact.isContact = true
        let osmStation = place("ORLEN", northMeters: 7_000, category: "amenity=fuel")
        var mapKitStation = place("Shell", northMeters: 8_000, category: "MKPOICategoryGasStation")
        mapKitStation.placeProvider = .mapKit
        let intent = QueryClassifier().classify("stacja benzynowa")
        let context = SearchContext(origin: origin)
        let candidates = [bank, unclassified, contact, osmStation, mapKitStation]
        let partial = SearchDeduplicator.mergeAndRank(candidates, intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin, allowsExpansion: false)
        #expect(partial.isEmpty)
        let final = SearchDeduplicator.mergeAndRank(candidates, intent: intent,
            context: context, searchCenter: origin, routeOrigin: origin)
        #expect(Set(final.map(\.id)) == Set([osmStation.id, mapKitStation.id]))
        #expect(final.allSatisfy { !$0.isContact })
    }

    @Test func genericCategoriesAndBrandsWithoutACenterCannotReturnArbitraryPlaces() {
        let candidate = place("ORLEN", northMeters: 1_000)
        for query in ["stacja benzynowa", "Orlen"] {
            for allowsExpansion in [false, true] {
                let results = SearchDeduplicator.mergeAndRank([candidate],
                    intent: QueryClassifier().classify(query), context: SearchContext(origin: nil),
                    searchCenter: nil, routeOrigin: nil, allowsExpansion: allowsExpansion)
                #expect(results.isEmpty)
            }
        }
    }
}
#endif
