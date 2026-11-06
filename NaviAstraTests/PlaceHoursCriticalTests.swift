import Foundation
import Testing
@testable import NaviAstra

/// Critical regressions: a false open/closed claim or another branch's schedule
/// can send a traveller to an inaccessible destination.
@MainActor
struct PlaceHoursCriticalTests {
    private let warsaw = Coordinate(latitude: 52.23, longitude: 21.01)

    @Test func legacyNegativeStationCacheDoesNotBlockTheNewLookupSource() throws {
        let identity = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 12")
        var cached = PlaceDetails.partial(for: identity)
        cached.cacheGroupFetchedAt = ["identity": Date(), "contact": Date(), "hours": Date(), "access": Date()]
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(cached, for: identity) == nil)
        cached.openingHours = "   "
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(cached, for: identity) == nil)
        cached.openingHours = "24/7"
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(cached, for: identity)?.openingHours == "24/7")
        cached.cacheGroupFetchedAt?["hours"] = Date().addingTimeInterval(-13 * 3_600)
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(cached, for: identity) == nil)
    }

    @Test func stationLookupRequiresExactTypedIdentityAndValidatedFuelAddress() throws {
        let identity = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "Stacja benzynowa", category: "fuel", address: "Polna 12")
        func record(id: Int = 42, osmType: String = "node", category: String = "amenity",
                    type: String = "fuel", latitude: String = "52.23", street: String = "Polna",
                    number: String = "12", hours: String? = "24/7", includesAddress: Bool = true) throws -> NominatimFuelStationLookup.Record {
            var tags = ["operator": "BP"]
            tags["opening_hours"] = hours
            let object: [String: Any] = ["osm_id": id, "osm_type": osmType, "category": category,
                "type": type, "lat": latitude, "lon": "21.01", "name": "BP",
                "address": includesAddress ? ["road": street, "house_number": number, "country_code": "pl"] : ["country_code": "pl"],
                "extratags": tags]
            return try JSONDecoder().decode(NominatimFuelStationLookup.Record.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        let valid = try record()
        #expect(valid.tags(for: identity)?["opening_hours"] == "24/7")
        #expect(valid.tags(for: identity)?["operator"] == "BP")
        // Identical duplicate objects are harmless; conflicting copies are not.
        #expect(NominatimFuelStationLookup.records([valid, valid], matching: identity) == valid)
        #expect(NominatimFuelStationLookup.records([try record(includesAddress: false), valid], matching: identity) == valid)
        #expect(NominatimFuelStationLookup.records([valid, try record(hours: "Mo-Fr 09:00-17:00")], matching: identity) == nil)
        for invalid in [try record(id: 43), try record(osmType: "way"), try record(type: "cafe"),
                        try record(category: "shop"), try record(latitude: "51.23"),
                        try record(latitude: "nan"), try record(street: "Leśna"), try record(number: "14")] {
            #expect(invalid.tags(for: identity) == nil)
        }
        let missingHours = try record(hours: nil)
        #expect(NominatimFuelStationLookup.records([missingHours], matching: identity) != nil)
        #expect(missingHours.tags(for: identity)?["opening_hours"] == nil)
        let untyped = PlaceIdentity(provider: .openFreeMap, externalID: "42", osmType: nil,
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 12")
        #expect(NominatimFuelStationLookup.object(for: untyped) == nil)
        #expect(valid.tags(for: untyped) == nil)
    }

    @Test func stationLookupPublishesReadyHoursBeforeSlowRemainingStations() async throws {
        let first = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 12")
        let second = PlaceIdentity(provider: .openStreetMap, externalID: "43", osmType: "node",
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 14")
        var fallbackKeys: [String] = []
        var fallbackCancelled = false
        let batch = FuelStationHoursBatch(resolver: { identities in
            fallbackKeys = identities.map(\.cacheKey)
            do { try await Task.sleep(for: .seconds(60)) }
            catch { fallbackCancelled = true; throw error }
            return [:]
        }, lookup: { _ in
            var details = PlaceDetails.partial(for: first)
            details.openingHours = "24/7"
            // Missing hours are still eligible for the independent OSM fallback.
            return [FuelStationHoursBatch.requestKey(first): details,
                    FuelStationHoursBatch.requestKey(second): PlaceDetails.partial(for: second)]
        })
        var ready: PlaceDetails?
        var firstFinished = false
        let one = Task { ready = await batch.details(for: first); firstFinished = true }
        let two = Task { await batch.details(for: second) }
        for _ in 0..<200 {
            if firstFinished && !fallbackKeys.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstFinished)
        #expect(ready?.openingHours == "24/7")
        #expect(fallbackKeys == [second.cacheKey])
        two.cancel()
        one.cancel()
        _ = await (one.value, two.value)
        for _ in 0..<50 {
            if fallbackCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fallbackCancelled)
    }

    @Test func sameOSMIDDoesNotShareHoursAcrossConflictingAddressesOrCoordinates() async throws {
        let first = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 12")
        let otherAddress = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Leśna 12")
        let otherLocation = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: Coordinate(latitude: 51, longitude: 21), name: "BP", category: "fuel", address: "Polna 12")
        let json = #"{"osm_id":42,"osm_type":"node","category":"amenity","type":"fuel","lat":"52.23","lon":"21.01","address":{"road":"Polna","house_number":"12"},"extratags":{"opening_hours":"24/7"}}"#
        let record = try JSONDecoder().decode(NominatimFuelStationLookup.Record.self, from: Data(json.utf8))
        var resolved = PlaceDetails.partial(for: first)
        resolved.openingHours = "24/7"
        resolved.coordinate = record.coordinate
        let batch = FuelStationHoursBatch(resolver: { _ in [:] }, lookup: { identities in
            Dictionary(uniqueKeysWithValues: identities.compactMap { identity in
                guard NominatimFuelStationLookup.records([record], matching: identity) != nil else { return nil }
                return (FuelStationHoursBatch.requestKey(identity), resolved)
            })
        })
        async let one = batch.details(for: first)
        async let two = batch.details(for: otherAddress)
        async let three = batch.details(for: otherLocation)
        let values = await (one, two, three)
        #expect(values.0?.openingHours == "24/7")
        #expect(values.1 == nil)
        #expect(values.2 == nil)
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(resolved, for: first)?.openingHours == "24/7")
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(resolved, for: otherAddress) == nil)
        #expect(OpenStreetMapPlaceDetailsProvider.reusableFuelHours(resolved, for: otherLocation) == nil)
    }

    @Test func laterTypedStationLookupDoesNotWaitForAnEarlierOverpassBatch() async throws {
        let earlier = PlaceIdentity(provider: .mapKit, externalID: nil, providerID: "apple-station", osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 12")
        let later = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 14")
        var fallbackStarted = false
        var fallbackCancelled = false
        let fallback = FuelStationHoursBatch { _ in
            fallbackStarted = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { fallbackCancelled = true; throw error }
            return [:]
        }
        let lookup = FuelStationHoursBatch { identities in
            Dictionary(uniqueKeysWithValues: identities.map { identity in
                var details = PlaceDetails.partial(for: identity)
                details.openingHours = "24/7"
                return (FuelStationHoursBatch.requestKey(identity), details)
            })
        }
        let slow = Task { await FuelStationHoursBatch.resolvedDetails(for: earlier,
            lookupBatch: lookup, fallbackBatch: fallback) }
        for _ in 0..<200 {
            if fallbackStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fallbackStarted)
        var ready: PlaceDetails?
        let fast = Task { ready = await FuelStationHoursBatch.resolvedDetails(for: later,
            lookupBatch: lookup, fallbackBatch: fallback) }
        for _ in 0..<200 {
            if ready != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready?.openingHours == "24/7")
        #expect(!fallbackCancelled)
        slow.cancel()
        fast.cancel()
        _ = await (slow.value, fast.value)
        for _ in 0..<50 {
            if fallbackCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fallbackCancelled)
    }

    @Test func fuelHoursBatchMatchesOnlyTheSelectedStation() throws {
        let identity = PlaceIdentity(provider: .mapKit, externalID: nil, osmType: nil,
            coordinate: warsaw, name: "Stacja benzynowa", category: "MKPOICategoryGasStation", address: "Polna 12")
        func station(_ id: Int, type: String = "node", number: String = "12", name: String = "ORLEN",
                     longitude: Double = 21.01, amenity: String = "fuel") throws -> OpenStreetMapPlaceDetailsProvider.Element {
            let object: [String: Any] = ["id": id, "type": type, "lat": 52.23, "lon": longitude,
                "tags": ["name": name, "amenity": amenity, "addr:street": "Polna",
                         "addr:housenumber": number, "opening_hours": "24/7"]]
            return try JSONDecoder().decode(OpenStreetMapPlaceDetailsProvider.Element.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        let right = try station(1)
        #expect(OpenStreetMapPlaceDetailsProvider.fuelStationMatch(in: [right], for: identity)?.id == 1)
        #expect(OpenStreetMapPlaceDetailsProvider.fuelStationMatch(in: [try station(2, number: "14")], for: identity) == nil)
        #expect(OpenStreetMapPlaceDetailsProvider.fuelStationMatch(in: [right, try station(2)], for: identity) == nil)
        #expect(OpenStreetMapPlaceDetailsProvider.fuelStationMatch(in: [try station(3, amenity: "cafe")], for: identity) == nil)
        let typed = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "way",
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: nil)
        let match = OpenStreetMapPlaceDetailsProvider.fuelStationMatch(
            in: [try station(42), try station(42, type: "way")], for: typed)
        #expect(match?.type == "way")
    }

    @Test func visibleStationHoursRequestsCoalesceWithoutRefreshingSourceDates() async {
        let first = PlaceIdentity(provider: .mapKit, externalID: nil, providerID: "first", osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 12")
        let second = PlaceIdentity(provider: .mapKit, externalID: nil, providerID: "second", osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 14")
        let fetchedAt = Date().addingTimeInterval(-60)
        var calls: [[String]] = []
        let batch = FuelStationHoursBatch { identities in
            calls.append(identities.map(\.cacheKey))
            return Dictionary(uniqueKeysWithValues: identities.map { identity in
                var details = PlaceDetails.partial(for: identity)
                details.openingHours = "24/7"
                details.fetchedAt = fetchedAt
                return (FuelStationHoursBatch.requestKey(identity), details)
            })
        }
        async let one = batch.details(for: first)
        async let repeated = batch.details(for: first)
        async let two = batch.details(for: second)
        let values = await (one, repeated, two)
        #expect(calls.count == 1)
        #expect(Set(calls.first ?? []) == Set([first.cacheKey, second.cacheKey]))
        #expect(values.0?.openingHours == "24/7")
        #expect(values.1?.fetchedAt == fetchedAt)
        #expect(values.2?.fetchedAt == fetchedAt)
        let cached = await batch.details(for: first)
        #expect(calls.count == 1)
        #expect(cached?.fetchedAt == fetchedAt)
    }

    @Test func cancelledStationRowsReleaseBatchAndDoNotPoisonNextRequest() async throws {
        let identity = PlaceIdentity(provider: .mapKit, externalID: nil, providerID: "cancelled", osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 12")
        var calls = 0
        var cancelled = false
        let batch = FuelStationHoursBatch { identities in
            calls += 1
            if calls == 1 {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = true; throw error }
            }
            return Dictionary(uniqueKeysWithValues: identities.map { identity in
                var details = PlaceDetails.partial(for: identity)
                details.openingHours = "24/7"
                return (FuelStationHoursBatch.requestKey(identity), details)
            })
        }
        let request = Task { await batch.details(for: identity) }
        for _ in 0..<200 {
            if calls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls == 1)
        request.cancel()
        #expect(await request.value == nil)
        let replacement = await batch.details(for: identity)
        #expect(cancelled)
        #expect(calls == 2)
        #expect(replacement?.openingHours == "24/7")
    }

    @Test func freshSearchHoursIgnoreOldSupplementChecksWithoutRenewingExpiredExternalHours() {
        let now = Date()
        let old = now.addingTimeInterval(-24 * 3_600)
        let identity = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "Biblioteka", category: "library", address: "Polna 12")
        for websiteSource in [true, false] {
            var cached = PlaceDetails.partial(for: identity)
            cached.openingHours = "Mo-Su 06:00-23:00"
            cached.phone = "+48220000000"
            cached.fetchedAt = old
            cached.websiteHoursCheckedAt = old
            cached.wikidataCheckedAt = old
            cached.supplementalSource = PlaceSupplementalSource(title: "Wikidata",
                url: "https://www.wikidata.org/wiki/Q42", fields: ["godziny", "telefon"],
                fetchedAt: old, modifiedAt: nil)
            if websiteSource {
                cached.websiteHoursSource = PlaceSupplementalSource(title: "Strona miejsca",
                    url: "https://example.invalid/biblioteka", fields: ["godziny"],
                    fetchedAt: old, modifiedAt: nil)
            }
            // A newly delivered callback does not make its external hours fresh.
            var callback = cached
            callback.fetchedAt = now
            let visibleDetails = PlaceSearchOpeningHours.removingExpiredHours(from: callback, at: now)
            #expect(visibleDetails.openingHours == nil)
            #expect(visibleDetails.phone == cached.phone)
            #expect(visibleDetails.websiteHoursCheckedAt == old)

            let fresh = PlaceSearchOpeningHours.applyingSearchHours("Mo-Fr 09:00-17:00", to: cached, at: now)
            #expect(PlaceSearchOpeningHours.removingExpiredHours(from: fresh, at: now).openingHours == "Mo-Fr 09:00-17:00")
            #expect(fresh.websiteHoursSource == nil)
            #expect(fresh.supplementalSource?.fields == ["telefon"])
            #expect(fresh.cacheGroupFetchedAt?["hours"] == now)
            #expect(fresh.wikidataCheckedAt == old)
        }
    }

    @Test func lateSearchMetadataPreservesFreshHoursWithoutExtendingTheirLifetime() {
        let now = Date()
        let checkedAt = now.addingTimeInterval(-120)
        let identity = PlaceIdentity(provider: .mapKit, externalID: nil, osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 12")
        var callback = PlaceDetails.partial(for: identity)
        callback.openingHours = "24/7"
        callback.fetchedAt = checkedAt
        callback.cacheGroupFetchedAt = ["hours": checkedAt]
        callback.timeZoneIdentifier = "Europe/Warsaw"

        // A partial containing a newly discovered URL did not check hours.
        var lateSeed = PlaceDetails.partial(for: identity)
        lateSeed.website = "https://example.invalid/stacja"
        lateSeed.address = "Polna 12, Warszawa"
        let retained = PlaceSearchOpeningHours.reconcilingSeed(lateSeed, with: callback, at: now)
        #expect(retained.openingHours == "24/7")
        #expect(retained.website == lateSeed.website)
        #expect(retained.address == lateSeed.address)
        #expect(retained.timeZoneIdentifier == "Europe/Warsaw")
        #expect(retained.cacheGroupFetchedAt?["hours"] == checkedAt)
        #expect(PlaceSearchOpeningHours.removingExpiredHours(from: retained,
            at: checkedAt.addingTimeInterval(12 * 3_600)).openingHours == nil)

        // A real later OSM lookup with no schedule is authoritative.
        lateSeed.cacheGroupFetchedAt = ["hours": now]
        #expect(PlaceSearchOpeningHours.reconcilingSeed(lateSeed, with: callback, at: now).openingHours == nil)
        lateSeed.openingHours = "Mo-Fr 09:00-17:00"
        #expect(PlaceSearchOpeningHours.reconcilingSeed(lateSeed, with: callback, at: now).openingHours == lateSeed.openingHours)

        // A recycled row or an expired callback supplies no retained schedule.
        lateSeed.openingHours = nil
        lateSeed.cacheGroupFetchedAt = nil
        #expect(PlaceSearchOpeningHours.reconcilingSeed(lateSeed, with: nil, at: now).openingHours == nil)
        #expect(PlaceSearchOpeningHours.reconcilingSeed(lateSeed, with: callback,
            at: checkedAt.addingTimeInterval(12 * 3_600)).openingHours == nil)
    }

    @Test func freshOSMBatchClearsOldExternalHoursAttributionAndKeepsSourceDate() {
        let now = Date()
        let old = now.addingTimeInterval(-24 * 3_600)
        let fetchedAt = now.addingTimeInterval(-300)
        let identity = PlaceIdentity(provider: .mapKit, externalID: nil, osmType: nil,
            coordinate: warsaw, name: "ORLEN", category: "fuel", address: "Polna 12")
        var cached = PlaceDetails.partial(for: identity)
        cached.openingHours = "Mo-Fr 09:00-17:00"
        cached.websiteHoursCheckedAt = old
        cached.websiteHoursSource = PlaceSupplementalSource(title: "Strona miejsca",
            url: "https://example.invalid/stacja", fields: ["godziny"], fetchedAt: old, modifiedAt: nil)
        cached.supplementalSource = PlaceSupplementalSource(title: "Wikidata",
            url: "https://www.wikidata.org/wiki/Q42", fields: ["godziny", "telefon"], fetchedAt: old, modifiedAt: nil)
        cached.wikidataCheckedAt = old
        let seed = PlaceSearchOpeningHours.removingExpiredHours(from: cached, at: now)
        var station = PlaceDetails.partial(for: identity)
        station.source = .openStreetMap
        station.openingHours = "24/7"
        station.fetchedAt = fetchedAt
        station.cacheGroupFetchedAt = ["hours": fetchedAt]
        let merged = PlaceSearchOpeningHours.mergingOSMHours(station, into: seed)
        #expect(PlaceSearchOpeningHours.removingExpiredHours(from: merged, at: now).openingHours == "24/7")
        #expect(merged.websiteHoursSource == nil)
        #expect(merged.websiteHoursCheckedAt == nil)
        #expect(merged.supplementalSource?.fields == ["telefon"])
        #expect(merged.cacheGroupFetchedAt?["hours"] == fetchedAt)
        #expect(merged.fetchedAt == fetchedAt)
        #expect(PlaceSearchOpeningHours.removingExpiredHours(from: merged,
            at: fetchedAt.addingTimeInterval(12 * 3_600)).openingHours == nil)
    }

    @Test func cachedExternalHoursKeepTheirShorterLifetimeWhenReturnedByStationBatch() {
        let now = Date()
        let checkedAt = now.addingTimeInterval(-1_800)
        let identity = PlaceIdentity(provider: .openStreetMap, externalID: "42", osmType: "node",
            coordinate: warsaw, name: "BP", category: "fuel", address: "Polna 12")
        for website in [true, false] {
            var station = PlaceDetails.partial(for: identity)
            station.openingHours = "24/7"
            station.cacheGroupFetchedAt = ["hours": now]
            let source = PlaceSupplementalSource(title: website ? "Strona miejsca" : "Wikidata",
                url: "https://example.invalid/stacja", fields: ["godziny"], fetchedAt: checkedAt, modifiedAt: nil)
            if website {
                station.websiteHoursSource = source
                station.websiteHoursCheckedAt = checkedAt
            } else {
                station.supplementalSource = source
                station.wikidataCheckedAt = checkedAt
            }
            var seed = PlaceDetails.partial(for: identity)
            seed.supplementalSource = PlaceSupplementalSource(title: "Wikidata",
                url: "https://www.wikidata.org/wiki/Q42", fields: ["telefon"], fetchedAt: now, modifiedAt: nil)
            let merged = PlaceSearchOpeningHours.mergingOSMHours(station, into: seed)
            #expect(PlaceSearchOpeningHours.removingExpiredHours(from: merged, at: now).openingHours == "24/7")
            if website {
                #expect(merged.websiteHoursSource?.fetchedAt == checkedAt)
                #expect(merged.websiteHoursCheckedAt == checkedAt)
                #expect(merged.supplementalSource?.fields == ["telefon"])
            } else {
                #expect(merged.supplementalSource?.fetchedAt == checkedAt)
                #expect(merged.wikidataCheckedAt == checkedAt)
            }
            let lifetime: TimeInterval = website ? 6 * 3_600 : 3_600
            #expect(PlaceSearchOpeningHours.removingExpiredHours(from: merged,
                at: checkedAt.addingTimeInterval(lifetime)).openingHours == nil)
        }
    }

    @Test func hoursRespectLocalCalendarDSTHolidaysAndSolarPosition() async throws {
        let cases: [(String, String, String, Bool)] = [
            ("Mo-Fr 09:00-17:00", "2026-10-27T10:00:00Z", "Europe/Warsaw", true),
            ("Mo-Fr 09:00-17:00", "2026-10-27T16:00:00Z", "Europe/Warsaw", false),
            ("Su 01:00-04:00", "2026-03-29T01:30:00Z", "Europe/Warsaw", true),
            ("Su 01:00-04:00", "2026-10-25T01:30:00Z", "Europe/Warsaw", true),
            ("Su 02:00-02:45", "2026-10-25T01:30:00Z", "Europe/Warsaw", true),
            ("Fr 22:00-03:00", "2026-10-24T00:30:00Z", "Europe/Warsaw", true),
            ("Mo-Su 09:00-17:00", "2026-10-27T15:30:00Z", "America/New_York", true),
            ("Mo-Su 09:00-17:00", "2026-10-27T15:30:00Z", "Asia/Tokyo", false),
            ("Mo-Su 09:00-17:00; PH off", "2026-12-25T10:00:00Z", "Europe/Warsaw", false),
            ("sunrise-sunset", "2026-10-27T15:30:00Z", "Europe/Warsaw", false)
        ]
        let formatter = ISO8601DateFormatter()
        for (raw, instant, zone, expected) in cases {
            let now = try #require(formatter.date(from: instant))
            let presentation = await PlaceOpeningHours(rawValue: raw, coordinate: warsaw,
                countryCode: "pl", timeZoneIdentifier: zone).presentation(at: now)
            #expect(presentation.isOpen == expected, "\(raw), \(zone), \(instant)")
            #expect(presentation.weeklyRows?.count == 7)
        }
        let now = try #require(formatter.date(from: "2026-10-27T10:00:00Z"))
        let regular = await PlaceOpeningHours(rawValue: "Mo-Fr 09:00-17:00", coordinate: warsaw,
            countryCode: "pl", timeZoneIdentifier: "Europe/Warsaw").presentation(at: now)
        #expect(regular.statusText == "Otwarte · zamyka o 17:00")
        #expect(regular.weeklyRows?.first?.hours == "09:00–17:00")
        let noZone = await PlaceOpeningHours(rawValue: "24/7", coordinate: warsaw).presentation(at: now)
        #expect(noZone.isOpen == nil)
        let noLocation = await PlaceOpeningHours(rawValue: "sunrise-sunset").presentation(at: now)
        #expect(noLocation.failure == .locationUnavailable)
        let noCountry = await PlaceOpeningHours(rawValue: "PH off", coordinate: warsaw,
            timeZoneIdentifier: "Europe/Warsaw").presentation(at: now)
        #expect(noCountry.isOpen == nil)
    }

    @Test func matchingRejectsAnotherBranchAndUntypedIDCollisions() throws {
        let identity = PlaceIdentity(provider: .openFreeMap, externalID: "100", osmType: nil,
            coordinate: warsaw, name: "Sklep Alfa", category: "supermarket", address: "Polna 12")
        func element(_ name: String, number: String, lat: Double = 52.23,
                     alias: String? = nil) throws -> OpenStreetMapPlaceDetailsProvider.Element {
            var tags = ["name": name, "shop": "supermarket", "addr:housenumber": number]
            tags["alt_name"] = alias
            let json: [String: Any] = ["id": 100, "type": "way", "lat": lat, "lon": 21.01, "tags": tags]
            return try JSONDecoder().decode(OpenStreetMapPlaceDetailsProvider.Element.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(OpenStreetMapPlaceDetailsProvider.bestMatch(in: [try element("Inny sklep", number: "12")], for: identity) == nil)
        #expect(OpenStreetMapPlaceDetailsProvider.bestMatch(in: [try element("Sklep Alfa", number: "14")], for: identity) == nil)
        // A large building can place the map label over 100 metres from its OSM centre.
        let alias = try element("Nowa nazwa", number: "12", lat: 52.2311, alias: "Dawna nazwa;Sklep Alfa")
        #expect(OpenStreetMapPlaceDetailsProvider.bestMatch(in: [alias], for: identity)?.id == 100)
    }

    @Test func wikidataRejectsUnsupportedConditionsAndPreservesSplitHours() throws {
        func snak(_ value: Any) -> [String: Any] { ["snaktype": "value", "datavalue": ["value": value]] }
        func statement(_ value: Any, qualifiers: [String: Any] = [:]) -> [String: Any] {
            ["mainsnak": snak(value), "rank": "normal", "qualifiers": qualifiers]
        }
        func hours(_ start: String, _ end: String, extra: [String: Any] = [:]) -> [String: Any] {
            var q = extra
            q["P8626"] = [snak(["id": start])]; q["P8627"] = [snak(["id": end])]
            return statement(["id": "Q26214163"], qualifiers: q)
        }
        let related: [String: Any] = ["Q1": ["claims": ["P4895": [statement(["amount": "+540", "unit": "http://www.wikidata.org/entity/Q7727"])]]],
            "Q2": ["claims": ["P4895": [statement(["amount": "+720", "unit": "http://www.wikidata.org/entity/Q7727"])]]],
            "Q3": ["claims": ["P4895": [statement(["amount": "+840", "unit": "http://www.wikidata.org/entity/Q7727"])]]],
            "Q4": ["claims": ["P4895": [statement(["amount": "+61200", "unit": "http://www.wikidata.org/entity/Q11574"])]]]]
        let normal: [String: Any] = ["claims": ["P3025": [hours("Q1", "Q2"), hours("Q3", "Q4")]]]
        #expect(WikidataPlaceParser.values(normal, related: related).hours == "Mo-Su 09:00-12:00,14:00-17:00")
        let seasonal: [String: Any] = ["claims": ["P3025": [hours("Q1", "Q2", extra: ["P3027": [snak(["id": "Q2700"])]])]]]
        #expect(WikidataPlaceParser.values(seasonal, related: related).hours == nil)
        let unknown: [String: Any] = ["claims": ["P3025": [hours("Q1", "Q99")]]]
        #expect(WikidataPlaceParser.values(unknown, related: related).hours == nil)
        var closed = normal
        var claims = closed["claims"] as! [String: Any]
        claims["P3026"] = [statement(["id": "Q2705"])]
        closed["claims"] = claims
        #expect(WikidataPlaceParser.values(closed, related: related).hours == nil)
        let remote: [String: Any] = ["claims": ["P625": [statement(["latitude": 50.0, "longitude": 20.0,
                                                         "globe": "http://www.wikidata.org/entity/Q2"])]]]
        #expect(!WikidataPlaceParser.matchesCoordinate(remote, coordinate: warsaw))
    }

    @Test func retryAfterHonoursServerDateAndSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try #require(URL(string: "https://example.org"))
        let future = now.addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for header in ["120", formatter.string(from: future)] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                                       headerFields: ["Retry-After": header]))
            #expect(HTTPRetryDelay.date(from: response, minimum: 30, now: now) == future)
        }
    }
    @Test func websiteHoursRequireBranchIdentityAndRespectSpecialClosure() throws {
        let identity = PlaceIdentity(provider: .mapKit, externalID: nil, osmType: nil,
            coordinate: warsaw, name: "Restauracja Alfa", category: "restaurant", address: nil)
        let object: [String: Any] = ["@type": "Restaurant", "name": "Restauracja Alfa",
            "geo": ["latitude": 52.23, "longitude": 21.01],
            "openingHoursSpecification": [["dayOfWeek": "Friday", "opens": "09:00", "closes": "17:00"]],
            "specialOpeningHoursSpecification": [["validFrom": "2026-12-25", "validThrough": "2026-12-25",
                "opens": "00:00", "closes": "00:00"]]]
        let json = try JSONSerialization.data(withJSONObject: object)
        let html = "<script type='application/ld+json'>" + String(data: json, encoding: .utf8)! + "</script>"
        let hours = WebsiteHoursParser.hours(in: html, identity: identity, address: nil)
        #expect(hours == "Fr 09:00-17:00; 2026 Dec 25-2026 Dec 25 off")
        var anotherBranch = identity
        anotherBranch = PlaceIdentity(provider: .mapKit, externalID: nil, osmType: nil,
            coordinate: Coordinate(latitude: 51, longitude: 21), name: identity.name, category: "restaurant", address: nil)
        #expect(WebsiteHoursParser.hours(in: html, identity: anotherBranch, address: nil) == nil)
        var conflictingStreet = object
        conflictingStreet["address"] = ["streetAddress": "Leśna 12", "addressLocality": "Warszawa"]
        let conflictingJSON = try JSONSerialization.data(withJSONObject: conflictingStreet)
        let conflictingHTML = "<script type='application/ld+json'>" + String(data: conflictingJSON, encoding: .utf8)! + "</script>"
        #expect(WebsiteHoursParser.hours(in: conflictingHTML, identity: identity, address: "Polna 12, Warszawa") == nil)
        #expect(!PlaceAddressMatching.hasStreetConflict("ul. Polna 12, Warszawa", actual: "Polna 12"))
        let url = URL(string: "https://example.org/a/shop")!
        #expect(!WebsiteHoursParser.robotsAllow("User-agent: *\nDisallow: /a/", url: url))
        #expect(!WebsiteHoursParser.robotsAllow("User-agent: *\nDisallow: /%61/", url: url))
        #expect(WebsiteHoursParser.robotsAllow("User-agent: *\nDisallow: /a/\nAllow: /a/shop$", url: url))
        #expect(WebsiteOpeningHoursProvider.safeURL("https://192.168.1.1") == nil)
        #expect(WebsiteOpeningHoursProvider.safeURL("https://router.local") == nil)
    }

}
