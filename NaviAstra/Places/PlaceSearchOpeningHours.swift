import Foundation

/// The result list consumes the same detail cache as an expanded place, without
/// issuing a separate Overpass request for every row or delaying place search.
@MainActor
enum PlaceSearchOpeningHours {
    static func seed(_ result: SearchResult) async -> PlaceDetails? {
        guard result.isPOI, !result.isContact, var details = PlaceDetails.partial(for: result) else { return nil }
        if var cached = await OpenStreetMapPlaceDetailsProvider().cachedDetails(for: result.placeIdentity) {
            cached = removingExpiredHours(from: cached)
            if let raw = result.openingHours, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cached = applyingSearchHours(raw, to: cached)
            }
            cached.address = cached.address ?? details.address
            cached.website = cached.website ?? details.website
            cached.countryCode = cached.countryCode ?? result.countryCode
            cached.timeZoneIdentifier = cached.timeZoneIdentifier ?? result.timeZoneIdentifier
            cached.coordinate = cached.coordinate ?? result.destination.coordinate
            details = cached
        }
        if let city = result.city, !city.isEmpty, let street = result.street, !street.isEmpty {
            let streetLine = [street, result.houseNumber].compactMap { $0 }.joined(separator: " ")
            details.address = streetLine + ", " + city
        } else if details.address == nil {
            let street = [result.street, result.houseNumber].compactMap { $0 }.joined(separator: " ")
            let address = [street.isEmpty ? nil : street, result.city].compactMap { $0 }.joined(separator: ", ")
            if !address.isEmpty { details.address = address }
        } else if let city = result.city, let address = details.address,
                  !SearchRanking.normalizedIdentity(address).contains(SearchRanking.normalizedIdentity(city)) {
            details.address = address + ", " + city
        }
        if details.openingHours?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            details.openingHours = nil
        }
        return details
    }

    /// The live detail callback follows the same freshness rules as disk cache.
    /// Retaining a result row must not extend an external schedule's lifetime.
    static func removingExpiredHours(from input: PlaceDetails, at date: Date = Date()) -> PlaceDetails {
        var details = input
        if date.timeIntervalSince(hoursFetchedAt(details) ?? details.fetchedAt) >= hoursLifetime(details) || details.officialHoursWeekExpired {
            details.openingHours = nil
        }
        return details
    }

    /// A new URL/address can restart a row's cache lookup after a detail callback.
    /// Preserve that callback's fresh schedule unless this seed actually checked
    /// hours more recently. A partial without hours is not a negative lookup.
    static func reconcilingSeed(_ input: PlaceDetails, with current: PlaceDetails?,
                                at date: Date = Date()) -> PlaceDetails {
        var seed = removingExpiredHours(from: input, at: date)
        guard let current else { return seed }
        let retained = removingExpiredHours(from: current, at: date)
        let checkedAt = hoursFetchedAt(seed).flatMap { checkedAt in
            date.timeIntervalSince(checkedAt) < hoursLifetime(seed) && !seed.officialHoursWeekExpired ? checkedAt : nil
        }
        guard retained.openingHours != nil,
              checkedAt.map({ $0 >= (hoursFetchedAt(retained) ?? retained.fetchedAt) }) != true else { return seed }
        seed.openingHours = retained.openingHours
        seed.openingHoursURL = retained.openingHoursURL
        seed.websiteHoursSource = retained.websiteHoursSource
        seed.websiteHoursCheckedAt = retained.websiteHoursCheckedAt
        if retained.supplementalSource?.fields.contains("godziny") == true {
            seed.supplementalSource = retained.supplementalSource
            seed.wikidataCheckedAt = retained.wikidataCheckedAt
        } else if let source = seed.supplementalSource, source.fields.contains("godziny") {
            let fields = source.fields.filter { $0 != "godziny" && $0 != "informacje o godzinach" }
            seed.supplementalSource = fields.isEmpty ? nil : PlaceSupplementalSource(
                title: source.title, url: source.url, fields: fields,
                fetchedAt: source.fetchedAt, modifiedAt: source.modifiedAt)
        }
        var groups = seed.cacheGroupFetchedAt ?? [:]
        groups["hours"] = retained.cacheGroupFetchedAt?["hours"] ?? retained.fetchedAt
        seed.cacheGroupFetchedAt = groups
        seed.timeZoneIdentifier = seed.timeZoneIdentifier ?? retained.timeZoneIdentifier
        seed.countryCode = seed.countryCode ?? retained.countryCode
        return seed
    }

    private static func hoursFetchedAt(_ details: PlaceDetails) -> Date? {
        if let source = details.websiteHoursSource {
            return details.websiteHoursCheckedAt ?? source.fetchedAt
        }
        if let source = details.supplementalSource, source.fields.contains("godziny") {
            return details.wikidataCheckedAt ?? source.fetchedAt
        }
        return details.cacheGroupFetchedAt?["hours"] ?? (details.openingHours == nil ? nil : details.fetchedAt)
    }

    private static func hoursLifetime(_ details: PlaceDetails) -> TimeInterval {
        if details.websiteHoursSource != nil { return 6 * 3_600 }
        if details.supplementalSource?.fields.contains("godziny") == true { return 3_600 }
        return 12 * 3_600
    }

    /// Fresh search tags are an OSM fact, independent of older website/contact checks.
    static func applyingSearchHours(_ raw: String, to cached: PlaceDetails, at date: Date = Date()) -> PlaceDetails {
        var details = cached
        if details.websiteHoursSource != nil || details.supplementalSource?.fields.contains("godziny") == true {
            details.openingHoursURL = nil
        }
        details.openingHours = raw
        details.websiteHoursSource = nil
        details.websiteHoursCheckedAt = nil
        if let source = details.supplementalSource {
            let fields = source.fields.filter { $0 != "godziny" && $0 != "informacje o godzinach" }
            details.supplementalSource = fields.isEmpty ? nil : PlaceSupplementalSource(
                title: source.title, url: source.url, fields: fields,
                fetchedAt: source.fetchedAt, modifiedAt: source.modifiedAt)
        }
        var groups = details.cacheGroupFetchedAt ?? [:]
        groups["hours"] = date
        details.cacheGroupFetchedAt = groups
        return details
    }

    static func mergingOSMHours(_ station: PlaceDetails, into details: PlaceDetails) -> PlaceDetails {
        var merged = details.merging(station)
        if let raw = station.openingHours, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged = applyingSearchHours(raw, to: merged,
                at: station.cacheGroupFetchedAt?["hours"] ?? station.fetchedAt)
            merged.openingHoursURL = station.openingHoursURL
            // A batch may reuse cached website/Wikidata hours. They retain their
            // actual provenance and shorter lifetime instead of becoming OSM tags.
            merged.websiteHoursSource = station.websiteHoursSource
            merged.websiteHoursCheckedAt = station.websiteHoursCheckedAt
            if let source = station.supplementalSource, source.fields.contains("godziny") {
                merged.supplementalSource = source
                merged.wikidataCheckedAt = station.wikidataCheckedAt
            }
        }
        return merged
    }

    static func enrich(_ details: PlaceDetails, result: SearchResult) async -> PlaceDetails {
        guard details.openingHours == nil else { return details }
        var identity = result.placeIdentity
        identity = PlaceIdentity(provider: identity.provider, externalID: identity.externalID,
            providerID: identity.providerID, osmType: identity.osmType, coordinate: identity.coordinate,
            name: identity.name, category: identity.category, address: details.address ?? identity.address,
            brand: identity.brand, operatorName: identity.operatorName,
            countryCode: identity.countryCode, timeZoneIdentifier: identity.timeZoneIdentifier)
        var base = details
        if PaliwoMapaFuelPriceProvider.isFuelStation(category: identity.category),
           let station = await FuelStationHoursBatch.resolvedDetails(for: identity) {
            guard !Task.isCancelled else { return details }
            base = mergingOSMHours(station, into: details)
        }
        guard !Task.isCancelled else { return details }
        return await OpenStreetMapPlaceDetailsProvider().supplementalDetails(base, for: identity, hoursOnly: true)
    }

    static func presentations(_ input: PlaceDetails, travelTime: Double?, at date: Date = Date()) async
        -> (now: OpeningHoursPresentation?, arrival: OpeningHoursPresentation?) {
        guard let hours = input.openingHours else { return (nil, nil) }
        var details = input
        if details.timeZoneIdentifier == nil, details.countryCode?.lowercased() == "pl" {
            details.timeZoneIdentifier = "Europe/Warsaw"
        }
        if details.timeZoneIdentifier == nil, let coordinate = details.coordinate {
            let context = await PlaceTimeZoneResolver.context(for: coordinate)
            details.timeZoneIdentifier = context?.timeZoneIdentifier
            details.countryCode = details.countryCode ?? context?.countryCode
        }
        guard let zone = details.timeZoneIdentifier else { return (nil, nil) }
        let schedule = PlaceOpeningHours(rawValue: hours, coordinate: details.coordinate,
            countryCode: details.countryCode, timeZoneIdentifier: zone)
        let now = await schedule.presentation(at: date)
        let arrival: OpeningHoursPresentation?
        if let time = travelTime, time.isFinite, time > 0, time <= 31_536_000 {
            arrival = await schedule.presentation(at: date.addingTimeInterval(time))
        } else { arrival = nil }
        return (now, arrival)
    }
}
