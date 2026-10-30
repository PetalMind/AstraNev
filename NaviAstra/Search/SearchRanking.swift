import Foundation

enum SearchRanking {
    static func locationMatch(_ result: SearchResult, location: String) -> Int {
        let tokens = QueryClassifier.normalize(location)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !["ul", "ulica", "al", "aleja", "aleje"].contains($0) }
        let address = normalizedIdentity([
            result.destination.name, result.destination.address, result.street,
            result.houseNumber, result.city
        ].compactMap { $0 }.joined(separator: " "))
        return tokens.filter { address.contains($0) }.count
    }

    static func precedes(_ lhs: SearchResult, _ rhs: SearchResult,
                         intent: ClassifiedQuery, context: SearchContext,
                         withTravelEstimates: Bool = false) -> Bool {
        if lhs.isContact != rhs.isContact { return lhs.isContact }
        if withTravelEstimates, intent.alongRoute {
            let left = validTravelTime(lhs.detour), right = validTravelTime(rhs.detour)
            if left != right { return (left ?? .infinity) < (right ?? .infinity) }
        }
        if intent.intent == .brand || intent.intent == .category {
            if let location = intent.location {
                let leftMatch = locationMatch(lhs, location: location)
                let rightMatch = locationMatch(rhs, location: location)
                if leftMatch != rightMatch { return leftMatch > rightMatch }
            }
            // Until road estimates arrive, use textual relevance. A geometric
            // offset must never be presented as the order of nearest branches.
            if withTravelEstimates, !intent.alongRoute {
                let left = validTravelTime(lhs.travelTime), right = validTravelTime(rhs.travelTime)
                if left != right { return (left ?? .infinity) < (right ?? .infinity) }
            }
        }
        let leftRelevance = relevance(lhs, intent: intent)
        let rightRelevance = relevance(rhs, intent: intent)
        if leftRelevance != rightRelevance { return leftRelevance > rightRelevance }
        if withTravelEstimates, !intent.alongRoute {
            let left = validTravelTime(lhs.travelTime), right = validTravelTime(rhs.travelTime)
            if left != right { return (left ?? .infinity) < (right ?? .infinity) }
        }
        if withTravelEstimates {
            let leftLocal = context.localDestinations.contains { $0.coordinate.distance(to: lhs.destination.coordinate) < 20 }
            let rightLocal = context.localDestinations.contains { $0.coordinate.distance(to: rhs.destination.coordinate) < 20 }
            if leftLocal != rightLocal { return leftLocal }
        }
        let leftDistance = lhs.travelDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let rightDistance = rhs.travelDistance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if withTravelEstimates, leftDistance != rightDistance {
            return (leftDistance ?? .infinity) < (rightDistance ?? .infinity)
        }
        let leftText = [lhs.destination.name, lhs.destination.address].compactMap { $0 }.joined(separator: " ")
        let rightText = [rhs.destination.name, rhs.destination.address].compactMap { $0 }.joined(separator: " ")
        let order = leftText.compare(rightText, options: [.caseInsensitive, .diacriticInsensitive, .numeric],
                                     locale: Locale(identifier: "pl_PL"))
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.placeIdentity.cacheKey < rhs.placeIdentity.cacheKey
    }

    private static func validTravelTime(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...31_536_000).contains($0) ? $0 : nil }
    }

    static func relevance(_ result: SearchResult, intent: ClassifiedQuery) -> Double {
        let query = normalizedIdentity(intent.text)
        let name = normalizedIdentity(result.destination.name)
        let brand = normalizedIdentity(result.brand ?? "")
        let operatorName = normalizedIdentity(result.operatorName ?? "")
        let category = normalizedIdentity(result.category ?? "")
        let address = normalizedIdentity(result.destination.address ?? "")
        let categoryFilter = normalizedIdentity(intent.photonTag?.split(separator: ":").last.map(String.init) ?? "")
        var score = 0.0
        if !query.isEmpty {
            if name == query { score += 1_000 }
            else if name.hasPrefix(query) { score += 780 }
            else if name.contains(query) { score += 600 }
            if brand == query { score += 750 }
            else if brand.contains(query), !query.isEmpty { score += 560 }
            if operatorName == query { score += 620 }
            else if operatorName.contains(query), !query.isEmpty { score += 440 }
            if address.contains(query) { score += 180 }

            // Tokenize before stripping punctuation and spaces. Otherwise a
            // multiword query becomes one token and ignores reordered addresses.
            let tokens = Set(QueryClassifier.normalize(intent.text)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            if !tokens.isEmpty {
                let searchable = [name, brand, operatorName, address,
                    normalizedIdentity(result.street ?? ""), normalizedIdentity(result.city ?? "")]
                    .joined(separator: " ")
                let matched = tokens.filter { searchable.contains($0) }.count
                score += Double(matched) / Double(tokens.count) * 220
            }
        }
        if intent.intent == .category, !categoryFilter.isEmpty {
            score += category.contains(categoryFilter) ? 240 : 0
        }
        if let importance = result.photonImportance {
            score += min(1, max(0, importance)) * 80
        }
        if result.placeProvider == .openStreetMap, OpenStreetMapObjectID(result.osmID) != nil { score += 12 }
        if result.category != nil { score += 5 }
        return score
    }

    static func normalizedIdentity(_ value: String) -> String {
        QueryClassifier.normalize(value).filter { $0.isLetter || $0.isNumber }
    }
}

enum SearchDeduplicator {
    static func mergeAndRank(
        _ candidates: [SearchResult],
        intent: ClassifiedQuery,
        context: SearchContext,
        searchCenter: Coordinate?,
        routeOrigin: Coordinate?
    ) -> [SearchResult] {
        var unique: [SearchResult] = []
        // A street's geocoded midpoint only scopes provider requests. Rank its
        // branches from the selected map area or the user's position, not that
        // midpoint, which can be several kilometres down the same street.
        let proximityCenter = intent.intent == .brand || intent.intent == .category
            ? context.area ?? context.origin ?? searchCenter : searchCenter
        for result in candidates {
            if let parcelQuery = intent.parcelQuery {
                guard parcelQuery.matches(result) else { continue }
            } else if intent.intent == .brand {
                let names = [result.destination.name, result.brand, result.operatorName]
                    .compactMap { $0 }.map(SearchRanking.normalizedIdentity)
                let query = SearchRanking.normalizedIdentity(intent.text)
                guard names.contains(where: { $0.contains(query) }) else { continue }
            }
            if intent.alongRoute {
                guard MapMatcher.project(result.destination.coordinate, onto: context.route)
                    .map({ $0.distanceFromRoute <= 1_500 }) == true else { continue }
            }
            if let matchIndex = unique.firstIndex(where: { samePlace($0, result) }) {
                unique[matchIndex] = unique[matchIndex].mergingMetadata(from: result)
                continue
            }
            var value = result
            value.straightDistance = proximityCenter.map { $0.distance(to: result.destination.coordinate) }
            value.requiresRouteEstimate = true
            value.travelEstimateStatus = routeOrigin == nil ? .unavailable : .calculating
            unique.append(value)
        }

        return unique.sorted { lhs, rhs in
            SearchRanking.precedes(lhs, rhs, intent: intent, context: context)
        }
    }

    static func samePlace(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        guard lhs.isContact == rhs.isContact else { return false }
        let leftIdentity = lhs.placeIdentity
        let rightIdentity = rhs.placeIdentity
        if leftIdentity.cacheKey == rightIdentity.cacheKey,
           (leftIdentity.externalID != nil || leftIdentity.providerID != nil) { return true }

        // Adjacent machines can have the same carrier and address but distinct OSM identities.
        if PlacePOIMapMarkerKind(category: lhs.category) == .parcels,
           PlacePOIMapMarkerKind(category: rhs.category) == .parcels,
           let leftID = lhs.osmID, let rightID = rhs.osmID, leftID != rightID { return false }

        let distance = lhs.destination.coordinate.distance(to: rhs.destination.coordinate)
        guard distance <= 45 else { return false }
        if hasConflictingHouseNumbers(lhs.destination.address, rhs.destination.address) { return false }

        let leftNames = Set([lhs.destination.name, lhs.brand, lhs.operatorName]
            .compactMap { $0 }.map { SearchRanking.normalizedIdentity($0) })
        let rightNames = Set([rhs.destination.name, rhs.brand, rhs.operatorName]
            .compactMap { $0 }.map { SearchRanking.normalizedIdentity($0) })
        let sharedNames = leftNames.intersection(rightNames).filter { !$0.isEmpty }
        guard !sharedNames.isEmpty else { return false }
        let titleMatch = SearchRanking.normalizedIdentity(lhs.destination.name)
            == SearchRanking.normalizedIdentity(rhs.destination.name)
        let categoriesAgree = categoriesCompatible(lhs.category, rhs.category)
        return titleMatch ? (distance <= 25 || (distance <= 45 && categoriesAgree))
            : distance <= 25 && categoriesAgree
    }

    private static func categoriesCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        let left = SearchRanking.normalizedIdentity(lhs)
        let right = SearchRanking.normalizedIdentity(rhs)
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func hasConflictingHouseNumbers(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        func numbers(_ address: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])\d+[a-zA-Z]?(?:/\d+)?(?![\p{L}\p{N}])"#) else { return [] }
            let range = NSRange(address.startIndex..<address.endIndex, in: address)
            return Set(regex.matches(in: address, range: range).compactMap { match in
                guard let range = Range(match.range, in: address) else { return nil }
                return PhotonSearchProvider.normalized(String(address[range]))
            })
        }
        let leftNumbers = numbers(lhs)
        let rightNumbers = numbers(rhs)
        return !leftNumbers.isEmpty && !rightNumbers.isEmpty && leftNumbers.isDisjoint(with: rightNumbers)
    }
}

/// Keeps the displayed row alive when another source enriches the same place.
/// Provider precedence still chooses the freshest metadata and ranking still
/// follows relevance and actual route estimates; only presentation identity is kept.
@MainActor
final class SearchResultIdentityRegistry {
    private var known: [SearchResult] = []

    func stabilize(_ results: [SearchResult]) -> [SearchResult] {
        var used = Set<UUID>()
        let stabilized = results.map { result in
            var value = result
            if let previous = known.first(where: {
                !used.contains($0.id) && SearchDeduplicator.samePlace($0, result)
            }) {
                value.destination.id = previous.id
            }
            used.insert(value.id)
            return value
        }
        // Keep a small history for rows temporarily displaced by a faster source.
        known = Array((stabilized + known.filter { !used.contains($0.id) }).prefix(64))
        return stabilized
    }
}
