#if os(iOS)
import Foundation

/// Decides whether a public search result is specific enough to start a route.
/// Contacts are resolved separately, before any public place search.
@MainActor
enum VoiceDestinationSelection {
    enum Outcome {
        case direct(SearchResult)
        case choices([SearchResult])
        case needsAddressDetails(String)
        case unavailable(String)
    }

    static func resolve(_ results: [SearchResult], query: String, origin: Coordinate?) -> Outcome {
        let query = VoiceAddressQuery.normalized(query)
        let intent = QueryClassifier().classify(query)
        let publicResults = results.filter { !$0.isContact && valid($0.destination.coordinate) }
        guard !publicResults.isEmpty else {
            if intent.intent == .address || intent.intent == .place || intent.intent == .unknown {
                return addressDetails(query)
            }
            return .unavailable("Nie znalazłam miejsca. Podaj dokładniejszą nazwę lub adres.")
        }
        if intent.intent == .brand || intent.intent == .category {
            let matching = publicResults.filter {
                matches($0, intent: intent) && matchesLocation($0, location: intent.location)
            }
            guard !matching.isEmpty else {
                return .unavailable("Nie znalazłam placówki zgodnej z podaną nazwą i lokalizacją. Podaj dokładniejszy cel.")
            }
            // An exact locker code identifies a place, not a nearby carrier.
            if intent.parcelQuery?.reference != nil {
                return matching.count == 1 ? .direct(matching[0]) : .choices(matching)
            }
            guard !intent.alongRoute else { return .choices(matching) }
            guard let origin, valid(origin) else {
                return .unavailable("Poczekaj na aktualną pozycję GPS, aby wybrać najbliższą placówkę.")
            }
            // Never compare a road distance with another result's straight-line
            // distance. If estimates are incomplete, use one geometric basis for
            // the entire group; route planning still validates the chosen place.
            let allHaveRoadDistances = matching.allSatisfy { roadDistance($0) != nil }
            let ordered = matching.sorted { left, right in
                let leftDistance = allHaveRoadDistances ? roadDistance(left)!
                    : origin.distance(to: left.destination.coordinate)
                let rightDistance = allHaveRoadDistances ? roadDistance(right)!
                    : origin.distance(to: right.destination.coordinate)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return SearchRanking.precedes(left, right, intent: intent, context: SearchContext(origin: origin))
            }
            return .direct(ordered[0])
        }

        let exact: [SearchResult]
        if let coordinate = intent.coordinate {
            exact = publicResults.filter { $0.destination.coordinate.distance(to: coordinate) < 1 }
        } else if intent.intent == .address {
            let matching = publicResults.filter { result in
                guard containsAllAddressTokens(intent.text, result: result) else { return false }
                switch buildingNumber(in: intent.text, result: result) {
                case .number(let number):
                    return PhotonSearchProvider.normalized(result.houseNumber) == number
                case .none: return true
                case .unverified: return false
                }
            }
            // Do not offer a street midpoint, another town, or building 14 when
            // the user requested 14A, even when it is the provider's only result.
            guard !matching.isEmpty else { return addressDetails(query) }
            let numbered = matching.filter {
                if case .number = buildingNumber(in: intent.text, result: $0) { return true }
                return false
            }
            if numbered.count == 1 { return .direct(numbered[0]) }
            return .choices(numbered.isEmpty ? matching : numbered)
        } else {
            let name = SearchRanking.normalizedIdentity(intent.text)
            exact = publicResults.filter {
                $0.isPOI && !name.isEmpty && SearchRanking.normalizedIdentity($0.destination.name) == name
            }
        }
        // A geocoded town or a street midpoint must never become an automatic
        // destination merely because its provider returned a single row.
        if exact.count == 1 { return .direct(exact[0]) }
        return .choices(exact.isEmpty ? publicResults : exact)
    }

    private static func addressDetails(_ query: String) -> Outcome {
        .needsAddressDetails("Nie znalazłam dokładnego celu „\(query)”. Podaj miejscowość albo popraw ulicę lub numer budynku.")
    }

    private static func matches(_ result: SearchResult, intent: ClassifiedQuery) -> Bool {
        guard result.isPOI else { return false }
        if let parcel = intent.parcelQuery { return parcel.matches(result) }
        if intent.intent == .brand {
            // A carrier can share a brand with a fuel station or a shop. Only
            // the primary category decides this exclusion: secondary pickup
            // metadata must not disqualify a real fuel station.
            if intent.photonTag != "amenity:post_office",
               ["parcellocker", "parcelpickup", "postoffice", "vendingmachine"].contains(categoryKey(result.category)) {
                return false
            }
            let identities = [result.brand, result.operatorName, result.destination.name].compactMap { $0 }
            guard identities.contains(where: { containsPhrase(intent.text, in: $0) }) else { return false }
        }
        if let tag = intent.photonTag, !tag.hasPrefix("brand:"),
           let requested = tag.split(separator: ":").last.map(String.init) {
            guard categoryMatches(result.category, requested: requested) else { return false }
            if requested == "post_office" {
                let name = QueryClassifier.normalize(result.destination.name)
                guard name.range(of: #"paczkomat|automat|parcel.?locker|punkt odbioru|punkt nadania"#,
                                 options: .regularExpression) == nil else { return false }
            }
        } else if intent.intent == .category {
            return false
        }
        return true
    }

    private static func categoryMatches(_ category: String?, requested: String) -> Bool {
        let key = categoryKey(category)
        let requested = SearchRanking.normalizedIdentity(requested)
        let aliases: [String: Set<String>] = [
            "fuel": ["fuel", "gasstation"],
            "chargingstation": ["chargingstation", "evcharger"],
            "supermarket": ["supermarket", "foodmarket"],
            "toilets": ["toilets", "restroom"]
        ]
        return (aliases[requested] ?? [requested]).contains(key)
    }

    private static func categoryKey(_ category: String?) -> String {
        guard let category else { return "" }
        var key = SearchRanking.normalizedIdentity(category.components(separatedBy: CharacterSet(charactersIn: ":=")).last ?? category)
        for prefix in ["mkpoicategory", "pointofinterestcategory"] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
            break
        }
        return key
    }

    private static func matchesLocation(_ result: SearchResult, location: String?) -> Bool {
        guard let location, !location.isEmpty else { return true }
        guard containsAllAddressTokens(location, result: result) else { return false }
        switch buildingNumber(in: location, result: result) {
        case .none: return true
        case .number(let number): return PhotonSearchProvider.normalized(result.houseNumber) == number
        case .unverified: return false
        }
    }

    private enum BuildingNumber {
        case none, number(String), unverified
    }

    private static func buildingNumber(in text: String, result: SearchResult) -> BuildingNumber {
        guard PhotonSearchProvider.houseNumber(in: text) != nil else { return .none }
        // Remove the known street before reading a building number: the two
        // occurrences of 11 in "11 Listopada 11" have different meanings.
        // MapKit-only rows copy the requested number into houseNumber, so that
        // field without a structured street cannot verify a numbered address.
        let placeName: String
        if let street = result.street, !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeName = street
        } else if result.placeProvider != .mapKit, let city = result.city {
            // Rural addresses can consist of a village and building number,
            // without a named street. These providers supply a structured number.
            placeName = city
        } else { return .unverified }
        let knownName = addressTokens(placeName).joined(separator: " ")
        guard knownName.contains(where: \.isLetter) else { return .unverified }
        let normalized = QueryClassifier.normalize(text)
            .replacingOccurrences(of: #"[^\p{L}\p{N}/-]+"#, with: " ", options: .regularExpression)
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: knownName)
            + #"(?![\p{L}\p{N}])"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else { return .unverified }
        let withoutStreet = normalized.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        guard let number = PhotonSearchProvider.houseNumber(in: withoutStreet) else { return .none }
        return .number(number)
    }

    private static func containsAllAddressTokens(_ text: String, result: SearchResult) -> Bool {
        // Photon and GUGiK can put the postcode only in their formatted title.
        // Use that title for postcode evidence, not for overriding structured
        // street/city fields with a similarly named place in another locality.
        let label = [result.destination.name, result.destination.address].compactMap { $0 }.joined(separator: " ")
        let candidatePostcodes = Set(postcodes(in: label))
        guard postcodes(in: text).allSatisfy(candidatePostcodes.contains) else { return false }
        let requested = addressTokens(removingPostcodes(from: text))
        let address = [result.destination.address, result.street, result.houseNumber, result.city]
            .compactMap { $0 }.joined(separator: " ")
        let actual = Set(addressTokens(removingPostcodes(from: address)))
        return !requested.isEmpty && requested.allSatisfy { actual.contains($0) }
    }

    private static let postcodePattern = #"(?<![\p{L}\p{N}])\d{2}-\d{3}(?![\p{L}\p{N}])"#

    private static func postcodes(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: postcodePattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func removingPostcodes(from text: String) -> String {
        text.replacingOccurrences(of: postcodePattern, with: " ", options: .regularExpression)
    }

    private static func addressTokens(_ text: String) -> [String] {
        let ignored: Set<String> = ["ul", "ulica", "ulicy", "al", "aleja", "aleje", "przy", "w", "we"]
        return words(VoiceAddressQuery.normalized(text)).filter { !ignored.contains($0) }
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let phrase = words(phrase).joined(separator: " ")
        return !phrase.isEmpty && (" " + words(text).joined(separator: " ") + " ").contains(" " + phrase + " ")
    }

    private static func words(_ text: String) -> [String] {
        QueryClassifier.normalize(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func roadDistance(_ result: SearchResult) -> Double? {
        result.travelDistance.flatMap { $0.isFinite && (0...400_000_000).contains($0) ? $0 : nil }
    }

    private static func valid(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude) && (-180...180).contains(coordinate.longitude)
    }
}
#endif
