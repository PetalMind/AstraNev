import Foundation
import os
import Darwin

/// On-demand reading of structured facts from the selected place's website.
/// No discovery crawl, JavaScript execution, login, cookies, API key or paid service.
@MainActor
enum WebsiteOpeningHoursProvider {
    private static var cache: [String: (hours: String?, checkedAt: Date)] = [:]
    private static var robots: [String: (text: String, checkedAt: Date)] = [:]
    private static var inFlight = false
    private static var cooldowns: [String: Date] = [:]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: WebsiteHoursRedirectPolicy(), delegateQueue: nil)
    }()

    static func enrich(_ original: PlaceDetails, for identity: PlaceIdentity,
                       forceRefresh: Bool = false) async -> PlaceDetails {
        guard original.openingHours == nil, identity.category != "parcel_pickup",
              original.category != "parcel_pickup", let raw = original.website,
              let url = safeURL(raw), let host = url.host else { return original }
        if !forceRefresh, let checked = original.websiteHoursCheckedAt,
           Date().timeIntervalSince(checked) < 6 * 3_600 { return original }
        let key = url.absoluteString + "/" + identity.cacheKey
        var details = original
        if !forceRefresh, let entry = cache[key], Date().timeIntervalSince(entry.checkedAt) < 6 * 3_600 {
            details.openingHours = entry.hours
            details.websiteHoursCheckedAt = entry.checkedAt
            if entry.hours != nil { details.websiteHoursSource = source(url: url, at: entry.checkedAt) }
            return details
        }
        do {
            // One website fetch at a time across all cards; task cancellation never
            // lets a previous card overwrite the newly selected place.
            while inFlight { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            guard cooldowns[host].map({ $0 <= Date() }) ?? true else { return original }
            // The same card may have queued twice before the first download ended.
            // Recheck after the shared serial gate instead of fetching its page twice.
            if !forceRefresh, let entry = cache[key], Date().timeIntervalSince(entry.checkedAt) < 6 * 3_600 {
                details.openingHours = entry.hours
                details.websiteHoursCheckedAt = entry.checkedAt
                if entry.hours != nil { details.websiteHoursSource = source(url: url, at: entry.checkedAt) }
                return details
            }
            inFlight = true
            defer { inFlight = false }
            let policy: String
            if let entry = robots[host], Date().timeIntervalSince(entry.checkedAt) < 86_400 {
                policy = entry.text
            } else {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.path = "/robots.txt"; components.query = nil; components.fragment = nil
                let (data, response) = try await fetch(components.url!, maximumBytes: 64_000)
                if response.statusCode == 404 { policy = "" }
                else {
                    guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return original }
                    policy = text
                }
                if robots.count >= 128 { robots.removeAll() }
                robots[host] = (policy, Date())
            }
            guard WebsiteHoursParser.robotsAllow(policy, url: url) else { return original }
            let (data, response) = try await fetch(url, maximumBytes: 1_000_000)
            guard response.statusCode == 200,
                  ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? ""),
                  let html = String(data: data, encoding: .utf8) else { return original }
            let hours = WebsiteHoursParser.hours(in: html, identity: identity, address: original.address)
            if cache.count >= 256 { cache.removeAll() }
            cache[key] = (hours, Date())
            details.websiteHoursCheckedAt = Date()
            if let hours {
                details.openingHours = hours
                details.websiteHoursSource = source(url: url, at: Date())
                details.openingHoursURL = url.absoluteString
            }
            return details
        } catch {
            // Website facts are optional. A failure never hides OSM/Apple data.
            if !(error is CancellationError) { cooldowns[host] = max(cooldowns[host] ?? .distantPast, Date().addingTimeInterval(60)) }
            return original
        }
    }

    static func safeURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              host.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,63}$"#,
                         options: .regularExpression) != nil,
              !["local", "localhost", "internal", "home", "lan", "onion", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? "") else { return nil }
        components.fragment = nil
        return components.url
    }

    private static func source(url: URL, at date: Date) -> PlaceSupplementalSource {
        PlaceSupplementalSource(title: "Strona miejsca", url: url.absoluteString, fields: ["godziny"],
                                fetchedAt: date, modifiedAt: nil)
    }

    private static func fetch(_ url: URL, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host, await WebsitePublicHost.isPublic(host) else { throw PlaceDetailsError.unavailable }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.139"
        request.setValue("NaviAstra/\(version) (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaceDetailsError.invalidResponse }
        if [429, 503].contains(http.statusCode), let host = url.host {
            cooldowns[host] = HTTPRetryDelay.date(from: http, minimum: 60)
        }
        guard response.expectedContentLength <= maximumBytes else { throw PlaceDetailsError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw PlaceDetailsError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }
}

/// Redirects may stay on the same public HTTPS host (or its www alias), at most
/// five times. A metadata URL must never redirect the device to a local service.
nonisolated private final class WebsiteHoursRedirectPolicy: NSObject, URLSessionTaskDelegate {
    private let counts = OSAllocatedUnfairLock(initialState: [Int: Int]())
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        func host(_ url: URL?) -> String? {
            url?.host?.lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        }
        let count = counts.withLock { counts in
            counts[task.taskIdentifier, default: 0] += 1
            return counts[task.taskIdentifier]!
        }
        guard count <= 5,
              let original = task.originalRequest?.url,
              let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, host(original) == host(url) else {
            completionHandler(nil); return
        }
        Task {
            let allowed = await WebsitePublicHost.isPublic(url.host ?? "")
            completionHandler(allowed ? request : nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        counts.withLock { $0[task.taskIdentifier] = nil }
    }
}

/// Parses data only. Unrecognised or conflicting conditions fail closed to "unknown".
enum WebsiteHoursParser {
    static func hours(in html: String, identity: PlaceIdentity, address: String?) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script\s*>"#,
                                                   options: .caseInsensitive) else { return nil }
        var schedules = Set<String>()
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(32) {
            guard let range = Range(match.range(at: 1), in: html), let data = String(html[range]).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            for object in objects(root) where matches(object, identity: identity, address: address) {
                guard let schedule = schedule(object) else { return nil }
                schedules.insert(schedule)
            }
        }
        return schedules.count == 1 ? schedules.first : nil
    }

    private static func objects(_ raw: Any) -> [[String: Any]] {
        if let list = raw as? [Any] { return list.flatMap { objects($0) } }
        guard let object = raw as? [String: Any] else { return [] }
        return [object] + (object["@graph"].map { objects($0) } ?? [])
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(_ object: [String: Any], identity: PlaceIdentity, address: String?) -> Bool {
        guard let name = object["name"] as? String, !normalized(identity.name).isEmpty,
              normalized(name) == normalized(identity.name),
              object["openingHours"] != nil || object["openingHoursSpecification"] != nil else { return false }
        let suppliedAddress = object["address"] as? [String: Any]
        let street = suppliedAddress?["streetAddress"] as? String
        if PlaceAddressMatching.hasStreetConflict(address, actual: street) { return false }
        if let expected = address.flatMap({ PhotonSearchProvider.houseNumber(in: $0) }),
           let street, let actual = PhotonSearchProvider.houseNumber(in: street), expected != actual { return false }
        if let geo = object["geo"] as? [String: Any] {
            func number(_ raw: Any?) -> Double? { (raw as? Double) ?? (raw as? String).flatMap(Double.init) }
            guard let lat = number(geo["latitude"]), let lon = number(geo["longitude"]),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return false }
            return identity.coordinate.distance(to: Coordinate(latitude: lat, longitude: lon)) <= 100
        }
        // Without coordinates require the full street, building number and town.
        guard let address, let street, let city = suppliedAddress?["addressLocality"] as? String,
              let number = PhotonSearchProvider.houseNumber(in: street),
              number == PhotonSearchProvider.houseNumber(in: address),
              normalized(street).count >= 5, normalized(city).count >= 3 else { return false }
        return normalized(address).contains(normalized(street)) && normalized(address).contains(normalized(city))
    }

    static func schedule(_ object: [String: Any]) -> String? {
        var grouped: [String: [String]] = [:]
        if object["openingHours"] != nil && object["openingHoursSpecification"] != nil { return nil }
        if let raw = object["openingHours"] {
            guard let values = strings(raw), !values.isEmpty else { return nil }
            let pattern = #"^(?:(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:[-,](?:Mo|Tu|We|Th|Fr|Sa|Su))*\s+)(?:[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9])(?:,[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9])*$"#
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "24/7" { for day in expand("Mo-Su") { grouped[day, default: []].append("00:00-24:00") }; continue }
                guard trimmed.range(of: pattern, options: .regularExpression) != nil,
                      let split = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
                let times = trimmed[split...].trimmingCharacters(in: .whitespaces)
                guard times.split(whereSeparator: { $0 == "," || $0 == "-" }).allSatisfy({ clock(String($0)) != nil }) else { return nil }
                for day in expand(String(trimmed[..<split])) { grouped[day, default: []].append(times) }
            }
        } else if let raw = object["openingHoursSpecification"] {
            guard let specs = specifications(raw), !specs.isEmpty else { return nil }
            for spec in specs {
                // A seasonal-only schedule cannot establish today's state outside
                // its validity. Preserve the website link rather than invent closure.
                guard spec["validFrom"] == nil, spec["validThrough"] == nil,
                      let days = days(spec["dayOfWeek"]), let times = times(spec) else { return nil }
                for day in days.split(separator: ",").map(String.init) { grouped[day, default: []].append(times) }
            }
        } else { return nil }
        guard !grouped.isEmpty else { return nil }
        guard grouped.values.allSatisfy({ !$0.contains("off") || Set($0).count == 1 }) else { return nil }
        // Keep multiple intervals on one selector in a single OSM rule.
        var rules = grouped.keys.sorted().map { "\($0) \(grouped[$0]!.sorted().joined(separator: ","))" }
        if let raw = object["specialOpeningHoursSpecification"] {
            // OSM carries a night's interval into the following day. A date-only
            // override cannot safely cancel just that carry without cancelling a
            // genuine next-day opening, so this mixed case remains unknown.
            let overnight = grouped.values.flatMap { $0 }.flatMap { $0.split(separator: ",") }.contains { interval in
                let ends = interval.split(separator: "-")
                return ends.count == 2 && ends[1] < ends[0]
            }
            guard !overnight else { return nil }
            guard let specs = specifications(raw) else { return nil }
            var special: [String: [String]] = [:]
            var dateRanges: [(from: String, through: String, selector: String)] = []
            for spec in specs {
                guard let from = spec["validFrom"] as? String, let through = spec["validThrough"] as? String,
                      let start = date(from), let end = date(through), from <= through,
                      let times = times(spec) else { return nil }
                let selector = start + "-" + end + (spec["dayOfWeek"].flatMap { days($0) }.map { " " + $0 } ?? "")
                if spec["dayOfWeek"] != nil, days(spec["dayOfWeek"]) == nil { return nil }
                guard !dateRanges.contains(where: { $0.selector != selector && $0.from <= through && $0.through >= from }) else { return nil }
                dateRanges.append((from, through, selector))
                special[selector, default: []].append(times)
            }
            guard special.values.allSatisfy({ !$0.contains("off") || Set($0).count == 1 }) else { return nil }
            rules += special.keys.sorted().map { "\($0) \(special[$0]!.sorted().joined(separator: ","))" }
        }
        return rules.joined(separator: "; ")
    }

    private static func expand(_ selector: String) -> [String] {
        let weekdays = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        return selector.split(separator: ",").flatMap { part -> [String] in
            let ends = part.split(separator: "-").map(String.init)
            guard let first = ends.first, let start = weekdays.firstIndex(of: first) else { return [] }
            if ends.count == 1 { return [first] }
            guard ends.count == 2, let end = weekdays.firstIndex(of: ends[1]) else { return [] }
            return (0...((end - start + 7) % 7)).map { weekdays[(start + $0) % 7] }
        }
    }

    private static func strings(_ raw: Any) -> [String]? {
        if let value = raw as? String { return [value] }
        return raw as? [String]
    }
    private static func specifications(_ raw: Any) -> [[String: Any]]? {
        if let value = raw as? [String: Any] { return [value] }
        return raw as? [[String: Any]]
    }
    private static func days(_ raw: Any?) -> String? {
        guard let raw, let values = strings(raw), !values.isEmpty else { return nil }
        let mapping = ["Monday": "Mo", "Tuesday": "Tu", "Wednesday": "We", "Thursday": "Th", "Friday": "Fr", "Saturday": "Sa", "Sunday": "Su"]
        let days = values.compactMap { mapping[$0.split(separator: "/").last.map(String.init) ?? ""] }
        guard days.count == values.count else { return nil }
        return Set(days).sorted().joined(separator: ",")
    }
    private static func times(_ spec: [String: Any]) -> String? {
        guard spec["description"] == nil, spec["disambiguatingDescription"] == nil else { return nil }
        if spec["opens"] == nil { return "off" }
        guard let rawStart = spec["opens"] as? String, let rawEnd = spec["closes"] as? String,
              let start = clock(rawStart), let end = clock(rawEnd) else { return nil }
        if start == "00:00", end == "00:00" { return "off" }
        if start == "00:00", end == "23:59" { return "00:00-24:00" }
        guard start != end else { return nil }
        return "\(start)-\(end)"
    }
    private static func clock(_ raw: String) -> String? {
        guard raw.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9](?::00)?$|^24:00(?::00)?$"#, options: .regularExpression) != nil else { return nil }
        return String(raw.prefix(5))
    }
    private static func date(_ raw: String) -> String? {
        guard raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        formatter.dateFormat = "yyyy MMM dd"
        return formatter.string(from: date)
    }

    private static func normalizedPath(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var result = "", index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37, index + 2 < bytes.count,
               let decoded = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .utf8) ?? "", radix: 16) {
                result += unreserved.contains(decoded) ? String(UnicodeScalar(decoded)) : String(format: "%%%02X", decoded)
                index += 3
            } else {
                result += byte < 128 ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
                index += 1
            }
        }
        return result
    }

    static func robotsAllow(_ text: String, url: URL) -> Bool {
        struct Group { var agents: [String] = []; var rules: [(allow: Bool, path: String)] = [] }
        var groups: [Group] = []; var current = Group(); var hasDirectives = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            if key == "user-agent" {
                if hasDirectives { groups.append(current); current = Group(); hasDirectives = false }
                current.agents.append(value.lowercased())
            } else if ["allow", "disallow"].contains(key), !current.agents.isEmpty {
                hasDirectives = true
                if !value.isEmpty { current.rules.append((key == "allow", value)) }
            } else if key == "crawl-delay", current.agents.contains(where: { $0 == "*" || $0 == "naviastra" }) {
                // Do not fetch when a site requests a crawling delay we cannot honour.
                return false
            }
        }
        groups.append(current)
        let specific = groups.filter { $0.agents.contains(where: { $0 == "naviastra" }) }
        let selected = specific.isEmpty ? groups.filter { $0.agents.contains("*") } : specific
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        let target = normalizedPath(path + (components?.percentEncodedQuery.map { "?" + $0 } ?? ""))
        let matches = selected.flatMap(\.rules).filter { rule in
            let anchor = rule.path.hasSuffix("$")
            let path = normalizedPath(anchor ? String(rule.path.dropLast()) : rule.path)
            let regex = "^" + path.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + (anchor ? "$" : "")
            return target.range(of: regex, options: .regularExpression) != nil
        }
        guard let longest = matches.map({ $0.path.utf8.count }).max() else { return true }
        return matches.contains { $0.path.utf8.count == longest && $0.allow }
    }
}

/// Reject private/link-local DNS answers before an on-device metadata request.
/// Resolve off the main actor so slow DNS cannot block the place card.
nonisolated private enum WebsitePublicHost {
    static func isPublic(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var addresses: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &addresses) == 0, let first = addresses else { return false }
            defer { freeaddrinfo(first) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            var found = false
            while let address = current {
                let info = address.pointee
                guard let raw = info.ai_addr else { return false }
                if info.ai_family == AF_INET {
                    let ip = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                    let n = UInt32(bigEndian: ip)
                    let a = n >> 24, b = (n >> 16) & 255
                    guard a > 0, a < 224, a != 10, a != 127,
                          !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                          !(a == 192 && (b == 168 || b == 0)), !(a == 100 && (64...127).contains(b)),
                          !(a == 198 && (b == 18 || b == 19)) else { return false }
                } else if info.ai_family == AF_INET6 {
                    let ip = UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: ip) { Array($0) }
                    guard bytes.count == 16, (0x20...0x3f).contains(bytes[0]),
                          !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) else { return false }
                } else { return false }
                found = true
                current = info.ai_next
            }
            return found
        }.value
    }
}
