#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

/// Choosing a public destination can start navigation without a second question.
@MainActor
struct VoiceDestinationSelectionCriticalTests {
    private let origin = Coordinate(latitude: 52, longitude: 21)

    @Test func postalOfficesDoNotBecomeCarrierParcelSearches() {
        for text in ["Poczta Polska", "Poczty Polskiej", "Poczta Polska w Warszawa"] {
            let query = QueryClassifier().classify(text)
            #expect(query.intent == .brand)
            #expect(query.text == "Poczta Polska")
            #expect(query.parcelQuery == nil)
            #expect(query.filter?.contains("[amenity=post_office]") == true)
            #expect(query.photonTag == "amenity:post_office")
        }
        let located = QueryClassifier().classify("Poczta Polska, ul. Długa 12, Warszawa")
        #expect(located.location == "ul. dluga 12, warszawa")
        let generic = QueryClassifier().classify("poczta")
        #expect(generic.intent == .category)
        #expect(generic.parcelQuery == nil)

        for text in ["Pocztex automat", "Poczta Polska paczkomat", "paczkomat Poczta Polska"] {
            let query = QueryClassifier().classify(text)
            #expect(query.parcelQuery?.scope == .lockers)
        }
        #expect(QueryClassifier().classify("Poczta Polska punkt odbioru").parcelQuery?.scope == .pickup)
    }

    @Test func closestWrongCarrierLockerOrContactCannotWinOverAPostalOffice() {
        var locker = office(1, road: 10)
        locker.category = "parcel_locker"
        var pickup = office(2, road: 20)
        pickup.category = "parcel_pickup"
        var otherBrand = office(3, road: 30)
        otherBrand.destination.name = "Deutsche Post"
        otherBrand.brand = "Deutsche Post"
        var contact = office(4, road: 40)
        contact.isContact = true
        var branch = office(5, road: 1_000)
        branch.destination.name = "Urząd Pocztowy Warszawa 12"
        branch.category = "MKPOICategoryPostOffice"

        let result = VoiceDestinationSelection.resolve([locker, pickup, otherBrand, contact, branch],
            query: "Poczta Polska", origin: origin)
        #expect(directID(result) == branch.id)
        let unavailable = VoiceDestinationSelection.resolve([locker, pickup, otherBrand, contact],
            query: "Poczta Polska", origin: origin)
        #expect(isUnavailable(unavailable))
    }

    @Test func nearestUsesRoadDistanceRatherThanProviderOrderOrTravelTime() {
        var near = office(1, road: 10_000)
        near.travelTime = 60
        var far = office(10, road: 1_200)
        far.travelTime = 300
        for candidates in [[near, far], [far, near]] {
            #expect(directID(VoiceDestinationSelection.resolve(candidates,
                query: "Poczta Polska", origin: origin)) == far.id)
        }
    }

    @Test func incompleteOrInvalidRoadEstimatesUseOneBasisForAllBranches() {
        let near = office(1, road: 10_000)
        for distance in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            let far = office(10, road: distance)
            #expect(directID(VoiceDestinationSelection.resolve([far, near],
                query: "Poczta Polska", origin: origin)) == near.id)
        }
        #expect(isUnavailable(VoiceDestinationSelection.resolve([near], query: "Poczta Polska", origin: nil)))
    }

    @Test func cityStreetAndHouseNumberRestrictTheEligibleBranches() {
        var otherCity = office(1, road: 100)
        otherCity.city = "Kraków"
        var otherStreet = office(2, road: 200)
        otherStreet.street = "Krótka"
        var otherNumber = office(3, road: 300)
        otherNumber.houseNumber = "120"
        let exact = office(4, road: 5_000)
        let candidates = [otherCity, otherStreet, otherNumber, exact]
        #expect(directID(VoiceDestinationSelection.resolve(candidates,
            query: "Poczta Polska, Długa 12, Warszawa", origin: origin)) == exact.id)
        #expect(isUnavailable(VoiceDestinationSelection.resolve(Array(candidates.prefix(3)),
            query: "Poczta Polska, Długa 12, Warszawa", origin: origin)))
    }

    @Test func specificPublicAddressNeedsAllTokensAndAnExactBuildingNumber() {
        var exact = office(2, road: nil)
        exact.destination.name = "Długa 12"
        exact.isPOI = false
        var wrong = exact
        wrong.destination.id = UUID()
        wrong.houseNumber = "120"
        #expect(directID(VoiceDestinationSelection.resolve([wrong, exact],
            query: "Warszawa, Długa 12", origin: nil)) == exact.id)
        #expect(directID(VoiceDestinationSelection.resolve([wrong],
            query: "Warszawa, Długa 12", origin: origin)) == nil)
        #expect(needsAddressDetails(VoiceDestinationSelection.resolve([wrong],
            query: "Warszawa, Długa 12", origin: origin)))
        var secondExact = exact
        secondExact.destination.id = UUID()
        secondExact.destination.coordinate.latitude += 1
        #expect(choiceCount(VoiceDestinationSelection.resolve([exact, secondExact],
            query: "Warszawa, Długa 12", origin: origin)) == 2)
    }

    @Test func ruralAddressesKeepTheBuildingLetterWithoutRequiringAStreet() {
        let exact = SearchResult(destination: Destination(name: "Nowa Wieś 24B",
            coordinate: origin), street: nil, houseNumber: "24B", city: "Nowa Wieś", countryCode: "pl")
        var wrongNumber = exact
        wrongNumber.destination.id = UUID()
        wrongNumber.houseNumber = "24"
        var wrongVillage = exact
        wrongVillage.destination.id = UUID()
        wrongVillage.city = "Stara Wieś"
        for query in ["Nowa Wieś 24B", "Nowa Wieś 24 B", "Nowa Wieś, numer 24 B"] {
            #expect(directID(VoiceDestinationSelection.resolve([wrongNumber, wrongVillage, exact],
                query: query, origin: nil)) == exact.id)
            #expect(needsAddressDetails(VoiceDestinationSelection.resolve([wrongNumber, wrongVillage],
                query: query, origin: origin)))
        }
        var anotherVillage = exact
        anotherVillage.destination.id = UUID()
        anotherVillage.destination.coordinate.latitude += 1
        #expect(choiceCount(VoiceDestinationSelection.resolve([exact, anotherVillage],
            query: "Nowa Wieś 24 B", origin: origin)) == 2)
    }

    @Test func missingOrConflictingAddressDetailsCannotBecomeASelectableFallback() {
        var exact = office(2, road: nil)
        exact.isPOI = false
        exact.houseNumber = "12A"
        let requested = "Długa 12A, Warszawa"
        for query in [requested, "Długa 12 A, Warszawa"] {
            #expect(directID(VoiceDestinationSelection.resolve([exact], query: query, origin: nil)) == exact.id)
            #expect(needsAddressDetails(VoiceDestinationSelection.resolve([], query: query, origin: origin)))
        }
        for mutation in ["number", "street", "city", "midpoint"] {
            var candidate = exact
            switch mutation {
            case "number": candidate.houseNumber = "12"
            case "street": candidate.street = "Krótka"
            case "city": candidate.city = "Kraków"
            default: candidate.houseNumber = nil
            }
            let outcome = VoiceDestinationSelection.resolve([candidate], query: requested, origin: origin)
            #expect(needsAddressDetails(outcome))
            #expect(choiceCount(outcome) == 0)
        }
    }

    @Test func resolverSendsOneNormalizedFullAddressWithoutSearchingContacts() async throws {
        var requestedQueries: [String] = []
        let candidate = SearchResult(destination: Destination(name: "Nowa Wieś 24B", coordinate: origin),
            street: nil, houseNumber: "24B", city: "Nowa Wieś", countryCode: "pl")
        let resolver = VoiceDestinationResolver(contacts: { _, _ in
            Issue.record("Pełny adres nie powinien być wyszukiwany jako kontakt.")
            return .noMatch
        }, places: { query, _ in
            requestedQueries.append(query)
            return [candidate]
        })
        let result = try await resolver.resolve("Nowa Wieś 24 B", context: SearchContext(origin: origin),
            currentOrigin: origin)
        #expect(requestedQueries == ["Nowa Wieś 24B"])
        #expect(directID(result) == candidate.id)
    }

    @Test func fullPostalAddressChecksThePostcodeWithoutReplacingStructuredLocalityWithTheTitle() {
        let exact = SearchResult(destination: Destination(name: "24B, 05-123 Nowa Wieś", coordinate: origin),
            street: nil, houseNumber: "24B", city: "Nowa Wieś", countryCode: "pl")
        var wrongCode = exact
        wrongCode.destination.id = UUID()
        wrongCode.destination.name = "24B, 05-124 Nowa Wieś"
        var wrongVillage = exact
        wrongVillage.destination.id = UUID()
        wrongVillage.city = "Stara Wieś"
        for query in ["05-123 Nowa Wieś 24 B", "Nowa Wieś 24B, 05-123"] {
            #expect(directID(VoiceDestinationSelection.resolve([wrongCode, wrongVillage, exact],
                query: query, origin: nil)) == exact.id)
            #expect(needsAddressDetails(VoiceDestinationSelection.resolve([wrongCode, wrongVillage],
                query: query, origin: origin)))
        }
    }

    @Test func numberedStreetCannotStandInForTheRequestedBuildingNumber() {
        var wrong = office(1, road: 100)
        wrong.street = "11 Listopada"
        wrong.houseNumber = "99"
        wrong.destination.address = "11 Listopada 99, Warszawa"
        var exact = office(2, road: 1_000)
        exact.street = "11 Listopada"
        exact.houseNumber = "11"
        #expect(directID(VoiceDestinationSelection.resolve([wrong, exact],
            query: "Poczta Polska, 11 Listopada 11, Warszawa", origin: origin)) == exact.id)
        #expect(isUnavailable(VoiceDestinationSelection.resolve([wrong],
            query: "Poczta Polska, 11 Listopada 11, Warszawa", origin: origin)))
        // The street itself remains a valid scope when no building was named.
        #expect(directID(VoiceDestinationSelection.resolve([wrong, exact],
            query: "Poczta Polska, 11 Listopada, Warszawa", origin: origin)) == wrong.id)
        #expect(choiceCount(VoiceDestinationSelection.resolve([exact],
            query: "11 Listopada, Warszawa", origin: origin)) == 1)

        var unverified = wrong
        unverified.street = nil
        unverified.houseNumber = "11" // MapKit's value comes from the query.
        unverified.placeProvider = .mapKit
        #expect(directID(VoiceDestinationSelection.resolve([unverified],
            query: "11 Listopada 11, Warszawa", origin: origin)) == nil)
        #expect(isUnavailable(VoiceDestinationSelection.resolve([unverified],
            query: "Poczta Polska, 11 Listopada 11, Warszawa", origin: origin)))
    }

    @Test func ordinaryBrandDoesNotSelectItsParcelServiceInsteadOfAFuelStation() {
        var locker = office(1, road: 10)
        locker.destination.name = "ORLEN Paczka"
        locker.brand = "ORLEN Paczka"
        var station = office(3, road: 1_000)
        station.destination.name = "ORLEN"
        station.brand = "ORLEN"
        station.category = "fuel"
        station.operatorName = "ORLEN Paczka"
        station.parcelReferences = ["PUNKT123"]
        for category in ["parcel_locker", "parcel_pickup", "post_office", "vending_machine"] {
            locker.category = category
            #expect(directID(VoiceDestinationSelection.resolve([locker, station],
                query: "Orlen", origin: origin)) == station.id)
            #expect(isUnavailable(VoiceDestinationSelection.resolve([locker], query: "Orlen", origin: origin)))
        }
    }

    @Test func exactUniqueNamedPOICanStartButStreetAndCityGeocodesCannot() {
        var museum = office(1, road: nil)
        museum.destination.name = "Muzeum Historii Polski"
        #expect(directID(VoiceDestinationSelection.resolve([museum],
            query: "Muzeum Historii Polski", origin: nil)) == museum.id)
        for name in ["Warszawa", "Długa"] {
            var geocode = museum
            geocode.isPOI = false
            geocode.destination.name = name
            #expect(choiceCount(VoiceDestinationSelection.resolve([geocode], query: name, origin: origin)) == 1)
        }
    }

    @Test func exactParcelReferenceCannotFallBackToADifferentNearbyLocker() {
        var requested = office(10, road: 1_000)
        requested.destination.name = "Paczkomat InPost WAW01M"
        requested.category = "parcel_locker"
        requested.brand = "InPost"
        requested.parcelReferences = ["WAW01M"]
        var closer = requested
        closer.destination.id = UUID()
        closer.destination.name = "Paczkomat InPost WAW02M"
        closer.parcelReferences = ["WAW02M"]
        closer.travelDistance = 10
        #expect(directID(VoiceDestinationSelection.resolve([closer, requested],
            query: "WAW01M", origin: nil)) == requested.id)
        #expect(isUnavailable(VoiceDestinationSelection.resolve([closer], query: "WAW01M", origin: origin)))
    }

    private func office(_ index: Int, road: Double?) -> SearchResult {
        SearchResult(destination: Destination(name: "Poczta Polska",
            coordinate: Coordinate(latitude: origin.latitude + Double(index) * 0.001, longitude: origin.longitude)),
            street: "Długa", houseNumber: "12", city: "Warszawa", countryCode: "pl",
            isPOI: true, category: "post_office", brand: "Poczta Polska", travelDistance: road)
    }

    private func directID(_ outcome: VoiceDestinationSelection.Outcome) -> UUID? {
        if case .direct(let result) = outcome { return result.id }
        return nil
    }

    private func choiceCount(_ outcome: VoiceDestinationSelection.Outcome) -> Int {
        if case .choices(let results) = outcome { return results.count }
        return 0
    }

    private func isUnavailable(_ outcome: VoiceDestinationSelection.Outcome) -> Bool {
        if case .unavailable = outcome { return true }
        return false
    }

    private func needsAddressDetails(_ outcome: VoiceDestinationSelection.Outcome) -> Bool {
        if case .needsAddressDetails = outcome { return true }
        return false
    }
}
#endif
