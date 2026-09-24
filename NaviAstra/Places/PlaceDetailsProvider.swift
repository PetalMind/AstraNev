import Foundation

enum PlaceProvider: String {
    case openStreetMap
    case openFreeMap
    case mapKit
}

struct PlaceIdentity {
    let provider: PlaceProvider
    let externalID: String?
    let osmType: String?
    let coordinate: Coordinate
    let name: String
    let category: String?
    let address: String?

    var cacheKey: String {
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
        let normalizedCategory = category?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber } ?? ""
        if provider == .openStreetMap, let osmType, let externalID,
           let object = OpenStreetMapObjectID("\(osmType):\(externalID)") {
            return object.cacheKey
        }
        if provider == .openFreeMap, let externalID, Int64(externalID) != nil {
            return "openfreemap/osm/\(externalID)/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))"
        }
        return "\(provider.rawValue)/near/\(normalizedName)/\(normalizedCategory)/\(Int((coordinate.latitude * 100_000).rounded()))/\(Int((coordinate.longitude * 100_000).rounded()))"
    }
}

struct PlaceDetails: Codable, Identifiable {
    var id: String
    var name: String
    var brand: String?
    var operatorName: String?
    var category: String?
    var address: String?
    var openingHours: String?
    var phone: String?
    var website: String?
    var wheelchair: String?
    var parking: String?
    var osmParking: ParkingInformation?
    var driveThrough: String?
    var source: PlaceDetailsSource
    var fetchedAt: Date

    @MainActor var openingHoursInfo: PlaceOpeningHours? {
        guard let openingHours else { return nil }
        return PlaceOpeningHours(rawValue: openingHours)
    }

    var websiteURL: URL? {
        guard let website else { return nil }
        let value = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var phoneURL: URL? {
        guard let phone else { return nil }
        let number = phone.filter { $0.isNumber || $0 == "+" }
        guard !number.isEmpty else { return nil }
        return URL(string: "tel:\(number)")
    }

    static func partial(for result: SearchResult) -> PlaceDetails? {
        return PlaceDetails(id: result.placeIdentity.cacheKey,
                            name: result.destination.name,
                            brand: result.brand,
                            operatorName: nil,
                            category: result.category,
                            address: result.destination.address,
                            openingHours: result.openingHours,
                            phone: result.phone,
                            website: result.website,
                            wheelchair: nil,
                            parking: nil,
                            osmParking: isParkingCategory(result.category) ? .unknown : nil,
                            driveThrough: nil,
                            source: result.placeProvider == .mapKit ? .mapKit : result.placeProvider == .openFreeMap ? .openFreeMap : .openStreetMap,
                            fetchedAt: Date())
    }

    static func partial(for identity: PlaceIdentity) -> PlaceDetails {
        PlaceDetails(id: identity.cacheKey,
                     name: identity.name,
                     brand: nil,
                     operatorName: nil,
                     category: identity.category,
                     address: identity.address,
                     openingHours: nil,
                     phone: nil,
                     website: nil,
                     wheelchair: nil,
                     parking: nil,
                     osmParking: isParkingCategory(identity.category) ? .unknown : nil,
                     driveThrough: nil,
                     source: identity.provider == .mapKit ? .mapKit : identity.provider == .openFreeMap ? .openFreeMap : .openStreetMap,
                     fetchedAt: Date())
    }

    func merging(_ newer: PlaceDetails) -> PlaceDetails {
        PlaceDetails(id: newer.id,
                     name: newer.name.isEmpty ? name : newer.name,
                     brand: newer.brand ?? brand,
                     operatorName: newer.operatorName ?? operatorName,
                     category: newer.category ?? category,
                     address: newer.address ?? address,
                     openingHours: newer.openingHours ?? openingHours,
                     phone: newer.phone ?? phone,
                     website: newer.website ?? website,
                     wheelchair: newer.wheelchair ?? wheelchair,
                     parking: newer.parking ?? parking,
                     osmParking: newer.osmParking ?? osmParking,
                     driveThrough: newer.driveThrough ?? driveThrough,
                     source: newer.source,
                     fetchedAt: newer.fetchedAt)
    }

    private static func isParkingCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return category.lowercased().split(separator: "=").last.map(String.init) == "parking"
    }
}

enum PlaceDetailsSource: String, Codable {
    case openStreetMap, mapKit, openFreeMap

    var title: String {
        switch self {
        case .openStreetMap: "OpenStreetMap"
        case .mapKit: "Apple Maps"
        case .openFreeMap: "OpenFreeMap / OpenStreetMap"
        }
    }
}

protocol PlaceDetailsProvider {
    func details(for identity: PlaceIdentity) async throws -> PlaceDetails?
}

struct OpenStreetMapPlaceDetailsProvider: PlaceDetailsProvider {
    private let endpoint = URL(string: UserDefaults.standard.string(forKey: "overpassServer") ?? "https://overpass-api.de/api/interpreter")!

    /// Search responses already contain full OSM tags; reuse them instead of fetching the same object again.
    static func cacheSearchDetails(_ objects: [(id: String, name: String, tags: [String: String])]) async {
        let details = objects.compactMap { object -> PlaceDetails? in
            guard let id = OpenStreetMapObjectID(object.id) else { return nil }
            return makeDetails(id: id.cacheKey, fallbackName: object.name, tags: object.tags)
        }
        await PlaceDetailsCache.shared.store(details)
    }

    func cachedDetails(for identity: PlaceIdentity) async -> PlaceDetails? {
        await PlaceDetailsCache.shared.value(for: identity.cacheKey, allowExpired: true)
    }

    func details(for identity: PlaceIdentity) async throws -> PlaceDetails? {
        try Task.checkCancellation()
        let value = try await PlaceDetailsRequests.load(key: endpoint.absoluteString + "/" + identity.cacheKey) {
            try await fetchDetails(for: identity)
        }
        try Task.checkCancellation()
        return value
    }

    private func fetchDetails(for identity: PlaceIdentity) async throws -> PlaceDetails? {
        let partial = PlaceDetails.partial(for: identity)
        let requestedID: OpenStreetMapObjectID?
        if identity.provider == .openStreetMap,
           let osmType = identity.osmType, let externalID = identity.externalID {
            requestedID = OpenStreetMapObjectID("\(osmType):\(externalID)")
        } else {
            requestedID = nil
        }
        let requestKey = identity.cacheKey
        if let cached = await PlaceDetailsCache.shared.value(for: requestKey) {
            return partial.merging(cached)
        }

        let selector: String
        if let requestedID {
            selector = "\(requestedID.selector);"
        } else {
            selector = "nwr(around:100,\(identity.coordinate.latitude),\(identity.coordinate.longitude))[\"name\"];"
        }
        let query = "[out:json][timeout:6];\(selector)out center tags;"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra/1.0 (OpenStreetMap place details)", forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaceDetailsError.unavailable
        }
        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw PlaceDetailsError.invalidResponse
        }
        guard reply.remark == nil else { throw PlaceDetailsError.unavailable }
        let element: Element?
        if let requestedID {
            element = reply.elements.first(where: { $0.type == requestedID.type && $0.id == requestedID.value })
        } else {
            let expectedName = Self.normalized(identity.name)
            let candidates = reply.elements.compactMap { candidate -> (element: Element, distance: Double, categoryMatch: Bool)? in
                guard let tags = candidate.tags,
                      let coordinate = candidate.coordinate else { return nil }
                if identity.provider == .openFreeMap, let externalID = identity.externalID {
                    guard let tileID = Int64(externalID), tileID != Int64.min,
                          (candidate.id == tileID || candidate.id == abs(tileID)),
                          Self.matchesExactName(expectedName, tags: tags),
                          coordinate.distance(to: identity.coordinate) <= 100 else { return nil }
                } else {
                    guard Self.matchesExactName(expectedName, tags: tags),
                          coordinate.distance(to: identity.coordinate) <= 40 else { return nil }
                }
                let categoryMatch = identity.category.map { Self.matchesCategory($0, tags: tags) } ?? false
                return (candidate, coordinate.distance(to: identity.coordinate), categoryMatch)
            }
            element = candidates.min {
                if $0.categoryMatch != $1.categoryMatch { return $0.categoryMatch }
                return $0.distance < $1.distance
            }?.element
        }
        guard let element, let tags = element.tags,
              let resolvedID = OpenStreetMapObjectID("\(element.type):\(element.id)") else { return nil }
        let resolvedKey = resolvedID.cacheKey
        let downloaded = Self.makeDetails(id: resolvedKey, fallbackName: partial.name, tags: tags)
        await PlaceDetailsCache.shared.store(downloaded, for: Array(Set([resolvedKey, requestKey])))
        return partial.merging(downloaded)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func matchesExactName(_ expected: String, tags: [String: String]) -> Bool {
        guard !expected.isEmpty else { return false }
        for value in [tags["name"], tags["brand"], tags["operator"]].compactMap({ $0 }) {
            if normalized(value) == expected { return true }
        }
        return false
    }

    private static func matchesCategory(_ expected: String, tags: [String: String]) -> Bool {
        let category = normalized(expected)
        guard !category.isEmpty else { return false }
        return tags.keys.contains(where: { normalized($0) == category }) ||
            tags.values.contains(where: { normalized($0) == category })
    }

    private static func makeDetails(id: String, fallbackName: String, tags: [String: String]) -> PlaceDetails {
        let streetLine = [tags["addr:street"], tags["addr:housenumber"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [tags["addr:postcode"], tags["addr:city"] ?? tags["addr:place"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let structuredAddress = [streetLine.isEmpty ? nil : streetLine,
                                 tags["addr:suburb"],
                                 locality.isEmpty ? nil : locality]
            .compactMap { $0 }
            .joined(separator: ", ")
        let address = tags["addr:full"] ?? (structuredAddress.isEmpty ? nil : structuredAddress)
        let category = ["amenity", "shop", "tourism", "leisure", "office", "craft"]
            .compactMap { tags[$0] }
            .first

        return PlaceDetails(id: id,
                            name: tags["name"] ?? tags["brand"] ?? fallbackName,
                            brand: tags["brand"],
                            operatorName: tags["operator"],
                            category: category,
                            address: address,
                            openingHours: tags["opening_hours"],
                            phone: tags["contact:phone"] ?? tags["phone"],
                            website: tags["contact:website"] ?? tags["website"],
                            wheelchair: tags["wheelchair"],
                            parking: tags["parking"],
                            osmParking: ParkingInformation.fromOSMTags(tags),
                            driveThrough: tags["drive_through"],
                            source: .openStreetMap,
                            fetchedAt: Date())
    }

    private struct Reply: Decodable { let elements: [Element]; let remark: String? }
    private struct Element: Decodable {
        let id: Int64
        let type: String
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
        var coordinate: Coordinate? {
            guard let latitude = lat ?? center?.lat, let longitude = lon ?? center?.lon,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return Coordinate(latitude: latitude, longitude: longitude)
        }
    }
    private struct Center: Decodable { let lat: Double; let lon: Double }
}

enum PlaceDetailsError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Szczegóły miejsca z OpenStreetMap są chwilowo niedostępne."
        case .invalidResponse: "Usługa szczegółów miejsca zwróciła nieprawidłowe dane."
        }
    }
}

struct OpenStreetMapObjectID {
    let type: String
    let value: Int64

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 2, let value = Int64(parts[1]), value > 0 else { return nil }
        let type: String
        switch parts[0].lowercased() {
        case "n", "node": type = "node"
        case "w", "way": type = "way"
        case "r", "relation": type = "relation"
        default: return nil
        }
        self.type = type
        self.value = value
    }

    var cacheKey: String { "osm/\(type)/\(value)" }
    var selector: String { "\(type)(\(value))" }
}

/// Shared requests survive a card being collapsed, so reopening it reuses the same download.
@MainActor
private enum PlaceDetailsRequests {
    static var pending: [String: Task<PlaceDetails?, Error>] = [:]
    static var missingUntil: [String: Date] = [:]

    static func load(key: String, operation: @escaping @MainActor () async throws -> PlaceDetails?) async throws -> PlaceDetails? {
        if let pending = pending[key] { return try await pending.value }
        if let until = missingUntil[key], until > Date() { return nil }
        let task = Task { try await operation() }
        pending[key] = task
        defer { pending[key] = nil }
        let value = try await task.value
        if value == nil {
            missingUntil = missingUntil.filter { $0.value > Date() }
            if missingUntil.count >= 200 { missingUntil.removeAll() }
            missingUntil[key] = Date().addingTimeInterval(300)
        }
        return value
    }
}

private actor PlaceDetailsCache {
    static let shared = PlaceDetailsCache()
    private let fileURL: URL
    private let lifetime: TimeInterval = 24 * 60 * 60
    private var entries: [String: PlaceDetails] = [:]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviAstra", isDirectory: true)
        fileURL = directory.appendingPathComponent("place-details-cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: PlaceDetails].self, from: data) {
            entries = stored
        }
    }

    func value(for id: String, allowExpired: Bool = false) -> PlaceDetails? {
        guard let entry = entries[id] else { return nil }
        // Keep stale information available while the card refreshes it. Cache misses do no disk IO.
        guard allowExpired || Date().timeIntervalSince(entry.fetchedAt) < lifetime else { return nil }
        return entry
    }

    func store(_ details: PlaceDetails, for ids: [String]) {
        for id in ids { entries[id] = details }
        if entries.count > 1_000 {
            let newestEntries = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(1_000)
                .map { ($0.key, $0.value) }
            entries = Dictionary(uniqueKeysWithValues: newestEntries)
        }
        persist()
    }

    func store(_ details: [PlaceDetails]) {
        guard !details.isEmpty else { return }
        for detail in details { entries[detail.id] = detail }
        if entries.count > 1_000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(1_000).map { ($0.key, $0.value) })
        }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache write failure must not hide details that were just fetched.
        }
    }
}

struct PlaceOpeningHours {
    let rawValue: String
    private let schedule: [Int: [MinuteInterval]]?

    init(rawValue: String) {
        self.rawValue = rawValue
        schedule = Self.parse(rawValue)
    }

    func isOpen(at date: Date = Date(), calendar: Calendar = .current) -> Bool? {
        guard let schedule else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let day = (weekday + 5) % 7 // Foundation: Sunday=1; OSM: Monday=0.
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if schedule[day, default: []].contains(where: { $0.contains(minutes) }) { return true }
        let previousDay = (day + 6) % 7
        if schedule[previousDay, default: []].contains(where: { $0.continuesPastMidnight && $0.contains(minutes + 1_440) }) {
            return true
        }
        return false
    }

    func statusText(at date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let open = isOpen(at: date, calendar: calendar) else { return nil }
        guard open else { return "Zamknięte teraz" }
        guard let closingTime = closingTime(at: date, calendar: calendar) else { return "Otwarte teraz" }
        return "Otwarte · zamyka o \(closingTime.formatted(date: .omitted, time: .shortened))"
    }

    func closingTime(at date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let schedule else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let day = (weekday + 5) % 7
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if let interval = schedule[day, default: []].first(where: { $0.contains(minutes) }) {
            return endDate(for: interval, nextCalendarDay: interval.end >= 1_440, date: date, calendar: calendar)
        }
        let previousDay = (day + 6) % 7
        if let interval = schedule[previousDay, default: []].first(where: {
            $0.continuesPastMidnight && $0.contains(minutes + 1_440)
        }) {
            return endDate(for: interval, nextCalendarDay: false, date: date, calendar: calendar)
        }
        return nil
    }

    var weeklyRows: [(String, String)]? {
        guard let schedule else { return nil }
        let labels = ["Pon.", "Wt.", "Śr.", "Czw.", "Pt.", "Sob.", "Niedz."]
        return labels.enumerated().map { day, label in
            let intervals = schedule[day, default: []]
            let value = intervals.isEmpty ? "Zamknięte" : intervals.map(\.description).joined(separator: ", ")
            return (label, value)
        }
    }

    private static func parse(_ rawValue: String) -> [Int: [MinuteInterval]]? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "24/7" {
            guard let fullDay = MinuteInterval(start: 0, end: 1_440) else { return nil }
            return Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, [fullDay]) })
        }
        guard !normalized.isEmpty else { return nil }

        var schedule = [Int: [MinuteInterval]]()
        var assignedDays = Set<Int>()
        for clause in normalized.split(separator: ";", omittingEmptySubsequences: false).map(String.init) {
            let pieces = clause.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pieces.count == 2, let days = parseDays(String(pieces[0])),
                  !days.contains(where: { assignedDays.contains($0) }) else { return nil }
            let hours = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let intervals: [MinuteInterval]
            if hours == "off" || hours == "closed" {
                intervals = []
            } else {
                let parsed = hours.split(separator: ",", omittingEmptySubsequences: false).compactMap {
                    MinuteInterval(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard !parsed.isEmpty, parsed.count == hours.split(separator: ",", omittingEmptySubsequences: false).count else {
                    return nil
                }
                intervals = parsed
            }
            for day in days {
                assignedDays.insert(day)
                schedule[day] = intervals
            }
        }
        guard !assignedDays.isEmpty else { return nil }
        return schedule
    }

    private static func parseDays(_ value: String) -> [Int]? {
        let names = ["Mo": 0, "Tu": 1, "We": 2, "Th": 3, "Fr": 4, "Sa": 5, "Su": 6]
        var result = Set<Int>()
        for token in value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let ends = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard ends.count == 1 || ends.count == 2,
                  let start = names[ends[0]], let end = names[ends.last!] else { return nil }
            var day = start
            while true {
                result.insert(day)
                if day == end { break }
                day = (day + 1) % 7
            }
        }
        return result.isEmpty ? nil : result.sorted()
    }

    private func endDate(for interval: MinuteInterval, nextCalendarDay: Bool,
                         date: Date, calendar: Calendar) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        let targetDay = calendar.date(byAdding: .day, value: nextCalendarDay ? 1 : 0, to: startOfDay) ?? startOfDay
        return calendar.date(byAdding: .minute, value: interval.end % 1_440, to: targetDay)
    }
}

private struct MinuteInterval: CustomStringConvertible {
    let start: Int
    let end: Int

    init?(start: Int, end: Int) {
        guard (0..<1_440).contains(start), (1...1_440).contains(end), start != end else { return nil }
        self.start = start
        self.end = end < start ? end + 1_440 : end
    }

    init?(_ value: String) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Self.minutes(String(parts[0]), allowEndOfDay: false),
              let end = Self.minutes(String(parts[1]), allowEndOfDay: true) else { return nil }
        self.init(start: start, end: end)
    }

    var continuesPastMidnight: Bool { end > 1_440 }
    func contains(_ minute: Int) -> Bool { minute >= start && minute < end }
    var description: String { "\(Self.string(start % 1_440))–\(end == 1_440 ? "24:00" : Self.string(end % 1_440))" }

    private static func minutes(_ value: String, allowEndOfDay: Bool) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...59).contains(minutes) else { return nil }
        if allowEndOfDay, hours == 24, minutes == 0 { return 1_440 }
        guard (0...23).contains(hours) else { return nil }
        return hours * 60 + minutes
    }

    private static func string(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
