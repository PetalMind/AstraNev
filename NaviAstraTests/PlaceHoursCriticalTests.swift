import Foundation
import Testing
@testable import NaviAstra

/// Critical regressions: a false open/closed claim or another branch's schedule
/// can send a traveller to an inaccessible destination.
@MainActor
struct PlaceHoursCriticalTests {
    private let warsaw = Coordinate(latitude: 52.23, longitude: 21.01)

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
