import Foundation
import OSLog

/// Uses only the selected OSM object's wikidata tag, never a brand or a name search.
/// Wikidata structured statements are CC0; the public API needs no key/account.
@MainActor
enum WikidataPlaceDetailsProvider {
    private static let logger = Logger(subsystem: "NaviAstra", category: "WikidataPlaces")
    private static var cache: [String: (entity: [String: Any], date: Date)] = [:]
    private static var pending: [String: Task<[String: Any], Error>] = [:]
    private static var nextRequest = Date.distantPast
    private static var cooldown = Date.distantPast
    private static var requestInFlight = false

    static func enrich(_ original: PlaceDetails, for identity: PlaceIdentity,
                       forceRefresh: Bool = false) async -> PlaceDetails {
        guard identity.category != "parcel_pickup", original.category != "parcel_pickup",
              let id = original.wikidataID?.trimmingCharacters(in: .whitespacesAndNewlines),
              id.range(of: #"^Q[1-9][0-9]*$"#, options: .regularExpression) != nil,
              original.openingHours == nil || original.phone == nil || original.website == nil else { return original }
        if !forceRefresh, let checked = original.wikidataCheckedAt,
           Date().timeIntervalSince(checked) < 60 * 60 { return original }
        do {
            let entities = try await fetch([id], forceRefresh: forceRefresh)
            guard let entity = entities[id] as? [String: Any],
                  WikidataPlaceParser.matchesCoordinate(entity, coordinate: identity.coordinate) else { return original }
            let dependencies = WikidataPlaceParser.scheduleDependencies(entity)
            let related = dependencies.isEmpty ? [:] : try await fetch(dependencies, forceRefresh: false)
            let values = WikidataPlaceParser.values(entity, related: related)
            var details = original
            var fields: [String] = []
            if details.openingHours == nil, let hours = values.hours {
                details.openingHours = hours
                fields.append("godziny")
            }
            if details.phone == nil, let phone = values.phone { details.phone = phone; fields.append("telefon") }
            if details.website == nil, let website = values.website { details.website = website; fields.append("strona") }
            // Complex/seasonal statements still have a reviewable source. Do not turn
            // a partial interpretation into an unconditional open/closed claim.
            if original.openingHours == nil, values.hasHours, details.openingHoursURL == nil {
                details.openingHoursURL = values.hoursURL
            }
            if !fields.isEmpty || (original.openingHours == nil && values.hasHours) {
                details.supplementalSource = PlaceSupplementalSource(
                    title: "Wikidata", url: "https://www.wikidata.org/wiki/\(id)",
                    fields: fields.isEmpty ? ["informacje o godzinach"] : fields,
                    fetchedAt: Date(), modifiedAt: (entity["modified"] as? String).flatMap {
                        ISO8601DateFormatter().date(from: $0)
                    })
            }
            details.wikidataCheckedAt = Date()
            return details
        } catch {
            logger.notice("Supplement unavailable: \(String(describing: error), privacy: .public)")
            return original
        }
    }

    private static func fetch(_ ids: [String], forceRefresh: Bool) async throws -> [String: Any] {
        let ids = Array(Set(ids)).sorted()
        guard ids.count <= 50 else { throw PlaceDetailsError.invalidResponse }
        let missing = ids.filter { id in
            forceRefresh || cache[id].map { Date().timeIntervalSince($0.date) >= 3_600 } != false
        }
        if !missing.isEmpty {
            let key = missing.joined(separator: "|")
            let task: Task<[String: Any], Error>
            if let existing = pending[key] { task = existing }
            else {
                task = Task { @MainActor in
                    guard cooldown <= Date() else { throw PlaceDetailsError.unavailable }
                    while requestInFlight || nextRequest > Date() {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard cooldown <= Date() else { throw PlaceDetailsError.unavailable }
                    requestInFlight = true
                    nextRequest = Date().addingTimeInterval(1.1)
                    defer { requestInFlight = false }
                    var url = URLComponents(string: "https://www.wikidata.org/w/api.php")!
                    url.queryItems = [URLQueryItem(name: "action", value: "wbgetentities"),
                        URLQueryItem(name: "ids", value: key), URLQueryItem(name: "props", value: "claims|info"),
                        URLQueryItem(name: "format", value: "json")]
                    var request = URLRequest(url: url.url!)
                    request.timeoutInterval = 6
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.139"
                    request.setValue("NaviAstra/\(version) (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw PlaceDetailsError.invalidResponse }
                    if http.statusCode == 429 || http.statusCode == 503 {
                        cooldown = HTTPRetryDelay.date(from: http, minimum: 60)
                    }
                    guard (200...299).contains(http.statusCode), data.count <= 2_000_000,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          json["error"] == nil, let entities = json["entities"] as? [String: Any] else {
                        throw PlaceDetailsError.unavailable
                    }
                    return entities
                }
                pending[key] = task
            }
            defer { pending[key] = nil }
            let entities = try await task.value
            for (id, value) in entities {
                if let entity = value as? [String: Any] { cache[id] = (entity, Date()) }
            }
            if cache.count > 256 {
                cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.date > $1.value.date }.prefix(256).map { ($0.key, $0.value) })
            }
        }
        return ids.reduce(into: [:]) { $0[$1] = cache[$1]?.entity }
    }
}

struct PlaceSupplementalSource: Codable {
    let title: String
    let url: String
    let fields: [String]
    let fetchedAt: Date
    let modifiedAt: Date?
}

/// A deliberately conservative subset. Unsupported conditions invalidate the whole
/// schedule, including holidays, seasons and service-specific qualifiers.
enum WikidataPlaceParser {
    struct Values {
        var hours: String?
        var phone: String?
        var website: String?
        var hoursURL: String?
        var hasHours: Bool
    }

    static func matchesCoordinate(_ entity: [String: Any], coordinate: Coordinate) -> Bool {
        statements("P625", in: entity).contains { statement in
            guard let value = value(statement) as? [String: Any],
                  let lat = value["latitude"] as? Double, let lon = value["longitude"] as? Double,
                  value["globe"] as? String == "http://www.wikidata.org/entity/Q2",
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return false }
            return coordinate.distance(to: Coordinate(latitude: lat, longitude: lon)) <= 250
        }
    }

    static func scheduleDependencies(_ entity: [String: Any]) -> [String] {
        let ids = statements("P3025", in: entity).flatMap { statement -> [String] in
            guard let qualifiers = statement["qualifiers"] as? [String: [[String: Any]]] else { return [] }
            return ["P8626", "P8627"].flatMap { key in
                (qualifiers[key] ?? []).compactMap { entityID($0) }
            }
        }
        return Array(Set(ids)).sorted()
    }

    static func values(_ entity: [String: Any], related: [String: Any]) -> Values {
        let hours = statements("P3025", in: entity)
        let rules = hours.compactMap { rule($0, related: related) }
        let contacts = statements("P1329", in: entity).filter { ($0["qualifiers"] as? [String: Any] ?? [:]).isEmpty }
        let websites = statements("P856", in: entity).filter {
            Set(($0["qualifiers"] as? [String: Any] ?? [:]).keys).isSubset(of: ["P407"])
        }
        let phoneValues = Set(contacts.compactMap { value($0) as? String }.filter {
            $0.filter(\.isNumber).count >= 7 && $0.count < 80
        })
        let urls = websites.compactMap { value($0) as? String }.filter { safeURL($0) != nil }
        let referenceURLs = hours.flatMap { $0["references"] as? [[String: Any]] ?? [] }.flatMap {
            ($0["snaks"] as? [String: [[String: Any]]])?["P854"] ?? []
        }.compactMap { snakValue($0) as? String }.filter { safeURL($0) != nil }
        var grouped: [String: [String]] = [:]
        for rule in rules {
            let parts = rule.split(separator: " ", maxSplits: 1).map(String.init)
            grouped[parts[0], default: []].append(parts[1])
        }
        // Overlapping different day selectors have overriding semantics in OSM;
        // reject them rather than accidentally erase part of another day's hours.
        let selectors = Array(grouped.keys)
        let daySets = selectors.map { selector -> Set<String> in
            switch selector {
            case "Mo-Su": Set(["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])
            case "Mo-Sa": Set(["Mo", "Tu", "We", "Th", "Fr", "Sa"])
            case "Sa-Su": Set(["Sa", "Su"])
            default: Set([selector])
            }
        }
        let disjoint = daySets.enumerated().allSatisfy { i, days in
            daySets.dropFirst(i + 1).allSatisfy { days.isDisjoint(with: $0) }
        }
        let schedule = selectors.sorted().map { "\($0) \(grouped[$0]!.sorted().joined(separator: ","))" }.joined(separator: "; ")
        return Values(hours: !hours.isEmpty && rules.count == hours.count && disjoint && statements("P3026", in: entity).isEmpty ? schedule : nil,
                      phone: phoneValues.count == 1 ? phoneValues.first : nil,
                      website: Set(urls).count == 1 ? urls.first : nil,
                      hoursURL: Set(referenceURLs).count == 1 ? referenceURLs.first : nil,
                      hasHours: !hours.isEmpty)
    }

    private static func rule(_ statement: [String: Any], related: [String: Any]) -> String? {
        let days = ["Q105": "Mo", "Q127": "Tu", "Q128": "We", "Q129": "Th", "Q130": "Fr",
                    "Q131": "Sa", "Q132": "Su", "Q26214163": "Mo-Su", "Q21282379": "Mo-Sa",
                    "Q99528581": "Sa-Su"]
        guard let dayID = (value(statement) as? [String: Any])?["id"] as? String,
              let day = days[dayID],
              let qualifiers = statement["qualifiers"] as? [String: [[String: Any]]],
              Set(qualifiers.keys) == Set(["P8626", "P8627"]),
              let start = clock(qualifiers["P8626"], related: related),
              let end = clock(qualifiers["P8627"], related: related), start != end else { return nil }
        return "\(day) \(start)-\(end)"
    }

    private static func clock(_ snaks: [[String: Any]]?, related: [String: Any]) -> String? {
        guard let snaks, snaks.count == 1, let id = entityID(snaks[0]),
              let entity = related[id] as? [String: Any] else { return nil }
        let minutes = statements("P4895", in: entity).compactMap { statement -> Int? in
            guard let quantity = value(statement) as? [String: Any],
                  let raw = quantity["amount"] as? String, let amount = Double(raw), amount.isFinite,
                  let unit = quantity["unit"] as? String else { return nil }
            let value: Double
            switch unit {
            case "http://www.wikidata.org/entity/Q7727": value = amount
            case "http://www.wikidata.org/entity/Q11574": value = amount / 60
            case "http://www.wikidata.org/entity/Q25235": value = amount * 60
            default: return nil
            }
            guard (0..<1_440).contains(value), value.rounded() == value else { return nil }
            return Int(value)
        }
        guard Set(minutes).count == 1, let minute = minutes.first else { return nil }
        // This is parser syntax, not a user-visible date/time formatter.
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func statements(_ property: String, in entity: [String: Any]) -> [[String: Any]] {
        let claims = (entity["claims"] as? [String: [[String: Any]]])?[property] ?? []
        let active = claims.filter { $0["rank"] as? String != "deprecated" }
        let preferred = active.filter { $0["rank"] as? String == "preferred" }
        return preferred.isEmpty ? active : preferred
    }
    private static func value(_ statement: [String: Any]) -> Any? {
        (statement["mainsnak"] as? [String: Any]).flatMap { snakValue($0) }
    }
    private static func snakValue(_ snak: [String: Any]) -> Any? {
        guard snak["snaktype"] as? String == "value" else { return nil }
        return (snak["datavalue"] as? [String: Any])?["value"]
    }
    private static func entityID(_ snak: [String: Any]) -> String? {
        (snakValue(snak) as? [String: Any])?["id"] as? String
    }
    private static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
