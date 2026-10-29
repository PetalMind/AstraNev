import Foundation
import os

/// On-demand facts from a chain's public branch pages. There is no national
/// directory download, authenticated API, page script execution or third-party search.
@MainActor
enum OfficialStoreHoursProvider {
    private struct Cached { let result: Result?; let checkedAt: Date; let week: String }
    private struct Result { let hours: String; let url: URL; let checkedAt: Date }
    private struct Page { let branches: [OfficialStoreHoursParser.Branch]; let lastPage: Int; let checkedAt: Date }
    private struct Flight { let id: UUID; let task: Task<Result?, Never>; var callers: Set<UUID> }
    private struct PageFlight { let id: UUID; let task: Task<Page, Error>; var callers: Set<UUID> }
    private static var cache: [String: Cached] = [:]
    private static var pending: [String: Flight] = [:]
    private static var pages: [String: Page] = [:]
    private static var pendingPages: [String: PageFlight] = [:]
    private static var failedPages: [String: Date] = [:]
    private static var robots: (text: String, at: Date)?
    private static var pendingRobots: Task<String, Error>?
    private static var busy = false
    private static var nextRequest = Date.distantPast
    private static var cooldown = Date.distantPast
    private static let origin = URL(string: "https://www.biedronka.pl")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: OfficialStoreHoursRedirects(), delegateQueue: nil)
    }()

    static func enrich(_ original: PlaceDetails, for identity: PlaceIdentity,
                       forceRefresh: Bool = false) async -> PlaceDetails {
        guard original.openingHours == nil, identity.category != "parcel_pickup",
              original.category != "parcel_pickup",
              [identity.brand, original.brand, identity.name, original.name].compactMap({ $0 })
                .contains(where: { OfficialStoreHoursParser.normalized($0) == "biedronka" }),
              (48.8...55).contains(identity.coordinate.latitude),
              (13.8...24.4).contains(identity.coordinate.longitude),
              identity.countryCode.map({ $0.lowercased() == "pl" }) ?? true,
              let target = OfficialStoreHoursParser.target(address: original.address)
                ?? OfficialStoreHoursParser.target(address: identity.address) else { return original }
        let week = OfficialStoreHoursParser.weekKey(at: Date())
        let key = identity.cacheKey + "|" + target.citySlug + "|" + target.streetKey
        if !forceRefresh, let entry = cache[key], entry.week == week,
           Date().timeIntervalSince(entry.checkedAt) < (entry.result == nil ? 60 : 6 * 3_600) {
            return applying(entry.result, to: original)
        }
        guard !Task.isCancelled else { return original }
        let caller = UUID()
        let flight: Flight
        if var existing = pending[key] {
            existing.callers.insert(caller); pending[key] = existing; flight = existing
        } else {
            guard pending.count < 32, cooldown <= .now else { return original }
            let task = Task { await lookup(target, forceRefresh: forceRefresh) }
            flight = Flight(id: UUID(), task: task, callers: [caller]); pending[key] = flight
        }
        return await withTaskCancellationHandler {
            let result = await flight.task.value
            guard !Task.isCancelled else { release(key, caller: caller, id: flight.id); return original }
            if pending[key]?.id == flight.id {
                if cache.count >= 256 { cache.removeAll() }
                cache[key] = Cached(result: result, checkedAt: Date(), week: week)
            }
            release(key, caller: caller, id: flight.id)
            return applying(result, to: original)
        } onCancel: {
            Task { @MainActor in release(key, caller: caller, id: flight.id) }
        }
    }

    private static func release(_ key: String, caller: UUID, id: UUID) {
        guard var value = pending[key], value.id == id else { return }
        value.callers.remove(caller)
        if value.callers.isEmpty { value.task.cancel(); pending[key] = nil }
        else { pending[key] = value }
    }

    private static func applying(_ result: Result?, to original: PlaceDetails) -> PlaceDetails {
        guard let result, original.openingHours == nil else { return original }
        var details = original
        details.openingHours = result.hours
        details.openingHoursURL = result.url.absoluteString
        details.websiteHoursCheckedAt = result.checkedAt
        details.websiteHoursSource = PlaceSupplementalSource(title: "Biedronka · godziny orientacyjne",
            url: result.url.absoluteString, fields: ["godziny"], fetchedAt: result.checkedAt, modifiedAt: nil)
        details.countryCode = "pl"
        details.timeZoneIdentifier = "Europe/Warsaw"
        return details
    }

    private static func lookup(_ target: OfficialStoreHoursParser.Target, forceRefresh: Bool) async -> Result? {
        do {
            try Task.checkCancellation()
            let policy = try await robotsPolicy()
            var lastPage = 1
            // A single selected city only. Pages and concurrent row lookups share
            // downloads. Stop at the matching branch, or at the bounded city limit.
            for number in 1...12 {
                try Task.checkCancellation()
                let path = "/pl/sklepy/lista,city,\(target.citySlug)" + (number == 1 ? "" : ",page,\(number)")
                let url = origin.appendingPathComponent(path)
                guard WebsiteHoursParser.robotsAllow(policy, url: url) else { return nil }
                let listing = try await page(url, forceRefresh: forceRefresh)
                try Task.checkCancellation()
                lastPage = max(lastPage, listing.lastPage)
                let matches = listing.branches.filter { $0.matches(target) }
                guard matches.count <= 1 else { return nil }
                if let match = matches.first {
                    // Fetch the branch itself so nearby shops or a changed list
                    // cannot provide the selected branch's schedule accidentally.
                    guard WebsiteHoursParser.robotsAllow(policy, url: match.url) else { return nil }
                    let branchPage = try await page(match.url, forceRefresh: forceRefresh)
                    guard branchPage.branches.count == 1, let branch = branchPage.branches.first,
                          branch.matches(target), branch.url == match.url,
                          let hours = branch.schedule(at: branchPage.checkedAt) else { return nil }
                    return Result(hours: hours, url: branch.url, checkedAt: branchPage.checkedAt)
                }
                if number >= lastPage { break }
            }
        } catch {
            // Optional enrichment never replaces OSM/Apple facts or leaks a raw error.
        }
        return nil
    }

    private static func page(_ url: URL, forceRefresh: Bool) async throws -> Page {
        try Task.checkCancellation()
        let key = url.absoluteString + "|" + OfficialStoreHoursParser.weekKey(at: Date())
        if !forceRefresh, let entry = pages[key], Date().timeIntervalSince(entry.checkedAt) < 6 * 3_600 { return entry }
        if !forceRefresh, failedPages[key].map({ $0 > .now }) == true { throw URLError(.resourceUnavailable) }
        let caller = UUID()
        let flight: PageFlight
        if var existing = pendingPages[key] {
            existing.callers.insert(caller); pendingPages[key] = existing; flight = existing
        } else {
            guard pendingPages.count < 32 else { throw URLError(.resourceUnavailable) }
            let task = Task { @MainActor in
                let (data, response) = try await fetch(url, maximumBytes: 1_000_000)
                guard response.statusCode == 200,
                      ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? ""),
                      let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
                let parsed = OfficialStoreHoursParser.page(html, url: url)
                guard !parsed.branches.isEmpty else { throw URLError(.cannotParseResponse) }
                return Page(branches: parsed.branches, lastPage: parsed.lastPage, checkedAt: Date())
            }
            flight = PageFlight(id: UUID(), task: task, callers: [caller]); pendingPages[key] = flight
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await flight.task.value
                try Task.checkCancellation()
                if pendingPages[key]?.id == flight.id {
                    if pages.count >= 64 { pages.removeAll() }
                    pages[key] = result
                    failedPages[key] = nil
                }
                releasePage(key, caller: caller, id: flight.id)
                return result
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    if failedPages.count >= 128 { failedPages.removeAll() }
                    failedPages[key] = Date().addingTimeInterval(60)
                }
                releasePage(key, caller: caller, id: flight.id)
                throw error
            }
        } onCancel: {
            Task { @MainActor in releasePage(key, caller: caller, id: flight.id) }
        }
    }

    private static func releasePage(_ key: String, caller: UUID, id: UUID) {
        guard var value = pendingPages[key], value.id == id else { return }
        value.callers.remove(caller)
        if value.callers.isEmpty { value.task.cancel(); pendingPages[key] = nil }
        else { pendingPages[key] = value }
    }

    private static func robotsPolicy() async throws -> String {
        if let robots, Date().timeIntervalSince(robots.at) < 86_400 { return robots.text }
        if let task = pendingRobots { return try await task.value }
        let task = Task { @MainActor in
            let (data, response) = try await fetch(origin.appendingPathComponent("robots.txt"), maximumBytes: 64_000)
            if response.statusCode == 404 { return "" }
            guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else { throw URLError(.resourceUnavailable) }
            return text
        }
        pendingRobots = task
        defer { pendingRobots = nil }
        let text = try await task.value
        robots = (text, Date())
        return text
    }

    private static func fetch(_ url: URL, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https", url.host == "www.biedronka.pl", url.port == nil,
              url.user == nil, url.password == nil else { throw URLError(.badURL) }
        while busy || nextRequest > .now {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard cooldown <= .now else { throw URLError(.resourceUnavailable) }
        busy = true
        nextRequest = Date().addingTimeInterval(1.1)
        defer { busy = false }
        var request = URLRequest(url: url)
        request.setValue("text/html,text/plain", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("NaviAstra/\(version) (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.expectedContentLength <= maximumBytes else { throw URLError(.badServerResponse) }
            if [403, 429, 503].contains(http.statusCode) {
                cooldown = HTTPRetryDelay.date(from: http, minimum: http.statusCode == 403 ? 3_600 : 60)
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            return (data, http)
        } catch {
            if !Task.isCancelled { cooldown = max(cooldown, Date().addingTimeInterval(60)) }
            throw error
        }
    }
}

nonisolated private final class OfficialStoreHoursRedirects: NSObject, URLSessionTaskDelegate {
    private let counts = OSAllocatedUnfairLock(initialState: [Int: Int]())
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let count = counts.withLock { value in
            value[task.taskIdentifier, default: 0] += 1
            return value[task.taskIdentifier]!
        }
        guard count <= 3, let url = request.url, url.scheme == "https", url.host == "www.biedronka.pl",
              url.user == nil, url.password == nil, url.port == nil,
              url.path == "/robots.txt" || url.path.hasPrefix("/pl/sklepy/") else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        counts.withLock { $0[task.taskIdentifier] = nil }
    }
}

/// Parses only the bounded, server-rendered branch records. Any missing weekday,
/// unexpected condition, conflicting branch or date-specific table stays unknown.
nonisolated enum OfficialStoreHoursParser {
    struct Target: Sendable { let city: String; let citySlug: String; let streetKey: String; let number: String }
    struct Branch: Sendable {
        let city: String
        let street: String
        let url: URL
        let intervals: [[(Int, Int)]]
        let uncertainDates: [Date]
        func matches(_ target: Target) -> Bool {
            normalized(city) == normalized(target.city) && streetKey(street) == target.streetKey
                && houseNumber(street) == target.number
        }
        func schedule(at date: Date) -> String? {
            guard intervals.count == 7, let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy MMM dd"
            var rules = ["unknown"]
            for day in 0..<7 {
                guard let current = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                let previous = intervals[(day + 6) % 7]
                var ranges = previous.filter { $0.1 > 0 && $0.1 < $0.0 }.map { (0, $0.1) }
                ranges += intervals[day].map { ($0.0, $0.1 < $0.0 ? 1_440 : $0.1) }
                let times = ranges.isEmpty ? "off" : ranges.sorted { $0.0 < $1.0 }
                    .map { clock($0.0) + "-" + clock($0.1) }.joined(separator: ",")
                rules.append(formatter.string(from: current) + " " + times)
            }
            // The locator does not supply holiday hours for this branch. Never
            // turn an ordinary weekly schedule into a promise of holiday opening.
            rules.append("PH unknown")
            for exception in uncertainDates where calendar.dateInterval(of: .weekOfYear, for: date)?.contains(exception) == true {
                rules.append(formatter.string(from: exception) + " unknown")
            }
            return rules.joined(separator: "; ")
        }
    }

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "pl_PL"); value.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
    static func weekKey(at date: Date) -> String {
        String(calendar.dateInterval(of: .weekOfYear, for: date)?.start.timeIntervalSince1970 ?? 0)
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l").filter { $0.isLetter || $0.isNumber }
    }
    private static func streetKey(_ street: String) -> String {
        normalized(street.replacingOccurrences(of: #"^(?:ulica|ul\.?|aleja|aleje|al\.?|plac|pl\.?|osiedle|os\.?)\s*"#,
            with: "", options: [.regularExpression, .caseInsensitive]))
    }
    private static func houseNumber(_ value: String) -> String? {
        let withoutPostal = value.replacingOccurrences(of: #"\b\d{2}-\d{3}\b"#, with: "", options: .regularExpression)
        return matches(#"(?<![\p{L}\p{N}])\d+[a-zA-Z]?(?:/\d+)?(?![\p{L}\p{N}])"#, in: withoutPostal).last?.lowercased()
    }
    static func target(address: String?) -> Target? {
        guard let address, address.count < 400 else { return nil }
        let splitPostal = address.replacingOccurrences(of: #"\b\d{2}-\d{3}\b"#, with: ",", options: .regularExpression)
        let parts = splitPostal.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let streets = parts.filter { houseNumber($0) != nil && $0.contains(where: \.isLetter) }
        guard streets.count == 1, let street = streets.first, let number = houseNumber(street),
              let city = parts.last(where: { $0 != street && houseNumber($0) == nil
                  && !["polska", "poland", "pl"].contains(normalized($0)) }), city.count >= 2 else { return nil }
        let slug = city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        guard !slug.isEmpty, slug.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        return Target(city: city, citySlug: slug, streetKey: streetKey(street), number: number)
    }
    static func page(_ html: String, url: URL) -> (branches: [Branch], lastPage: Int) {
        let clean = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let uncertainDates = matches(#"<section\b[^>]*class=["'][^"']*\bsundays_info\b[^"']*["'][^>]*>([\s\S]*?)</section>"#,
            in: clean, group: 1).flatMap { matches(#"\b\d{2}\.\d{2}\.\d{4}\b"#, in: $0) }.compactMap(date)
        let listPattern = #"<li\b[^>]*class=["'][^"']*\bshopListElement\b[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: listPattern, options: .caseInsensitive) else { return ([], 1) }
        let starts = regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { Range($0.range, in: clean)?.lowerBound }
        var branches: [Branch] = []
        if !starts.isEmpty {
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : clean.endIndex
                if let branch = branch(String(clean[start..<end]), url: nil, uncertainDates: uncertainDates) { branches.append(branch) }
            }
        } else if let block = matches(#"<div\b[^>]*class=["'][^"']*\bshop_info\b[^"']*["'][^>]*>([\s\S]*?)<div\b[^>]*class=["']body["']"#,
            in: clean, group: 1).first, let branch = branch(block, url: url, uncertainDates: uncertainDates) { branches = [branch] }
        let lastPage = matches(#"/pl/sklepy/lista,city,[a-z0-9-]+,page,(\d+)"#, in: clean, group: 1).compactMap(Int.init).max() ?? 1
        return (Array(branches.prefix(40)), min(12, lastPage))
    }
    private static func branch(_ html: String, url: URL?, uncertainDates: [Date]) -> Branch? {
        guard let rawCity = matches(#"<h4\b[^>]*>([\s\S]*?)</h4>"#, in: html, group: 1).first,
              let street = matches(#"<(?:p|span)\b[^>]*class=["']shopAddress["'][^>]*>([\s\S]*?)(?:<br\s*/?>|</(?:p|span)>)"#,
                in: html, group: 1).first.map(text), !street.isEmpty else { return nil }
        let city = text(rawCity)
        let branchURL: URL
        if let url, url.path.range(of: #"^/pl/sklepy/shop,id,\d+$"#, options: .regularExpression) != nil { branchURL = url }
        else {
            guard let id = matches(#"href=["']/pl/sklepy/shop,id,(\d+)["']"#, in: html, group: 1).first,
                  let value = URL(string: "https://www.biedronka.pl/pl/sklepy/shop,id," + id) else { return nil }
            branchURL = value
        }
        let labels = ["poniedzialek", "wtorek", "sroda", "czwartek", "piatek", "sobota", "niedziela"]
        let rows = matches(#"<li\b[^>]*>([^<>:]+):\s*<span\b[^>]*class=["']hours(?:Saturday|Sunday)?["'][^>]*>([\s\S]*?)</span>\s*</li>"#,
            in: html, group: 0)
        guard rows.count == 7, matches(#"\b\d{2}[./-]\d{2}[./-]\d{4}\b|specialOpeningHours|validFrom|validThrough"#, in: html).isEmpty else { return nil }
        var intervals = Array(repeating: [(Int, Int)](), count: 7)
        var seen = Set<Int>()
        for row in rows {
            guard let label = matches(#"<li\b[^>]*>([^<>:]+):"#, in: row, group: 1).first,
                  let day = labels.firstIndex(of: normalized(text(label))), seen.insert(day).inserted,
                  let raw = matches(#"<span\b[^>]*>([\s\S]*?)</span>"#, in: row, group: 1).first,
                  let values = Self.intervals(text(raw)) else { return nil }
            intervals[day] = values
        }
        return Branch(city: city, street: street, url: branchURL, intervals: intervals, uncertainDates: uncertainDates)
    }
    private static func intervals(_ raw: String) -> [(Int, Int)]? {
        if normalized(raw) == "zamkniete" { return [] }
        if normalized(raw) == "calodobowo" { return [(0, 1_440)] }
        let ranges = raw.replacingOccurrences(of: "–", with: "-").split(separator: ",").map(String.init)
        guard !ranges.isEmpty, ranges.count <= 4 else { return nil }
        var result: [(Int, Int)] = []
        for range in ranges {
            let ends = range.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, let start = minutes(ends[0]), let end = minutes(ends[1]),
                  start < 1_440, start != end else { return nil }
            result.append((start, end))
        }
        return result
    }
    private static func minutes(_ raw: String) -> Int? {
        guard raw.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$|^24:00$"#, options: .regularExpression) != nil else { return nil }
        let values = raw.split(separator: ":").compactMap { Int($0) }
        return values[0] * 60 + values[1]
    }
    private static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), minute / 60, minute % 60) }
    private static func date(_ raw: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "pl_PL"); formatter.dateFormat = "dd.MM.yyyy"; formatter.isLenient = false
        guard let value = formatter.date(from: raw), formatter.string(from: value) == raw else { return nil }
        return value
    }
    private static func text(_ html: String) -> String {
        var value = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (encoded, plain) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"] {
            value = value.replacingOccurrences(of: encoded, with: plain)
        }
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func matches(_ pattern: String, in value: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).prefix(256).compactMap {
            guard let range = Range($0.range(at: group), in: value) else { return nil }
            return String(value[range])
        }
    }
}
