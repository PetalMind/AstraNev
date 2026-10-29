import Foundation

/// The result list consumes the same detail cache as an expanded place, without
/// issuing a separate Overpass request for every row or delaying place search.
@MainActor
enum PlaceSearchOpeningHours {
    static func seed(_ result: SearchResult) async -> PlaceDetails? {
        guard result.isPOI, !result.isContact, var details = PlaceDetails.partial(for: result) else { return nil }
        if var cached = await OpenStreetMapPlaceDetailsProvider().cachedDetails(for: result.placeIdentity) {
            let hoursDate = cached.websiteHoursCheckedAt ?? cached.wikidataCheckedAt
                ?? cached.cacheGroupFetchedAt?["hours"] ?? cached.fetchedAt
            let lifetime: TimeInterval = cached.websiteHoursSource != nil ? 6 * 3_600
                : cached.supplementalSource?.fields.contains("godziny") == true ? 3_600 : 12 * 3_600
            if Date().timeIntervalSince(hoursDate) >= lifetime || cached.officialHoursWeekExpired {
                cached.openingHours = nil
            }
            if let raw = result.openingHours, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cached.openingHours = raw
                cached.websiteHoursSource = nil
            }
            cached.address = cached.address ?? details.address
            cached.website = cached.website ?? details.website
            cached.countryCode = cached.countryCode ?? result.countryCode
            cached.timeZoneIdentifier = cached.timeZoneIdentifier ?? result.timeZoneIdentifier
            cached.coordinate = result.destination.coordinate
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

    static func enrich(_ details: PlaceDetails, result: SearchResult) async -> PlaceDetails {
        guard details.openingHours == nil else { return details }
        var identity = result.placeIdentity
        identity = PlaceIdentity(provider: identity.provider, externalID: identity.externalID,
            providerID: identity.providerID, osmType: identity.osmType, coordinate: identity.coordinate,
            name: identity.name, category: identity.category, address: details.address ?? identity.address,
            brand: identity.brand, operatorName: identity.operatorName,
            countryCode: identity.countryCode, timeZoneIdentifier: identity.timeZoneIdentifier)
        return await OpenStreetMapPlaceDetailsProvider().supplementalDetails(details, for: identity, hoursOnly: true)
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
