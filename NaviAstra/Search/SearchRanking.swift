import Foundation

enum SearchRanking {
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

            let tokens = Set(query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            if !tokens.isEmpty {
                let searchable = [name, brand, operatorName, address].joined(separator: " ")
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
        for result in candidates {
            if intent.intent == .brand {
                let names = [result.destination.name, result.brand, result.operatorName]
                    .compactMap { $0 }.map(QueryClassifier.normalize)
                let query = QueryClassifier.normalize(intent.text)
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
            value.straightDistance = searchCenter.map { $0.distance(to: result.destination.coordinate) }
            value.requiresRouteEstimate = true
            value.travelEstimateStatus = routeOrigin == nil ? .unavailable : .calculating
            unique.append(value)
        }

        return unique.sorted { lhs, rhs in
            if lhs.isContact != rhs.isContact { return lhs.isContact }
            let lhsRelevance = SearchRanking.relevance(lhs, intent: intent)
            let rhsRelevance = SearchRanking.relevance(rhs, intent: intent)
            if lhsRelevance != rhsRelevance { return lhsRelevance > rhsRelevance }
            if intent.alongRoute {
                let lhsOffset = MapMatcher.project(lhs.destination.coordinate, onto: context.route)?
                    .distanceFromRoute ?? .infinity
                let rhsOffset = MapMatcher.project(rhs.destination.coordinate, onto: context.route)?
                    .distanceFromRoute ?? .infinity
                if lhsOffset != rhsOffset { return lhsOffset < rhsOffset }
            }
            return (lhs.straightDistance ?? .infinity) < (rhs.straightDistance ?? .infinity)
        }
    }

    private static func samePlace(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        guard lhs.isContact == rhs.isContact else { return false }
        let leftIdentity = lhs.placeIdentity
        let rightIdentity = rhs.placeIdentity
        if leftIdentity.cacheKey == rightIdentity.cacheKey,
           (leftIdentity.externalID != nil || leftIdentity.providerID != nil) { return true }

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
