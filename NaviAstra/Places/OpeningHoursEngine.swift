import Foundation
import JavaScriptCore

nonisolated struct OpeningHoursInterval: Decodable, Equatable, Sendable {
    let startMilliseconds: Double
    let endMilliseconds: Double
    let unknown: Bool
    let clippedStart: Bool
    let clippedEnd: Bool

    enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start"
        case endMilliseconds = "end"
        case unknown
        case clippedStart
        case clippedEnd
    }

    var start: Date { Date(timeIntervalSince1970: startMilliseconds / 1_000) }
    var end: Date { Date(timeIntervalSince1970: endMilliseconds / 1_000) }
}

nonisolated struct OpeningHoursEvaluation: Decodable, Equatable, Sendable {
    let open: Bool
    let unknown: Bool
    var nextChangeMilliseconds: Double?
    let nextOpen: Bool?
    let nextUnknown: Bool
    let days: [[OpeningHoursInterval]]

    enum CodingKeys: String, CodingKey {
        case open, unknown, nextOpen, nextUnknown, days
        case nextChangeMilliseconds = "nextChange"
    }

    var nextChange: Date? {
        guard let nextChangeMilliseconds else { return nil }
        return Date(timeIntervalSince1970: nextChangeMilliseconds / 1_000)
    }
}

enum OpeningHoursFailure: Error, LocalizedError, Equatable, Sendable {
    case runtimeUnavailable
    case invalidExpression
    case timeZoneUnavailable
    case invalidDate
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Parser godzin otwarcia jest niedostępny."
        case .invalidExpression:
            "Nie udało się odczytać podanych godzin otwarcia."
        case .timeZoneUnavailable:
            "Nie udało się ustalić strefy czasowej tego miejsca."
        case .invalidDate:
            "Nie udało się obliczyć godzin dla wybranej daty."
        case .locationUnavailable:
            "Do obliczenia tych godzin potrzebne jest położenie miejsca."
        }
    }
}

struct OpeningHoursDayRow: Equatable, Sendable {
    let day: String
    let hours: String
}

struct OpeningHoursPresentation: Equatable, Sendable {
    let isAvailable: Bool
    let isOpen: Bool?
    let statusText: String?
    let weeklyRows: [OpeningHoursDayRow]?
    let failure: OpeningHoursFailure?

    static func unavailable(_ failure: OpeningHoursFailure) -> OpeningHoursPresentation {
        OpeningHoursPresentation(isAvailable: false, isOpen: nil, statusText: nil,
                                 weeklyRows: nil, failure: failure)
    }
}

actor OpeningHoursEngine {
    static let shared = OpeningHoursEngine()

    private static let resourceSubdirectory = "Resources/Vendor/OpeningHours"

    private var didLoadContext = false
    private var context: JSContext?

    func evaluate(rawValue: String, nowMilliseconds: Double, weekRanges: [[Double]],
                  coordinate: Coordinate?, countryCode: String?,
                  systemTimeZoneIdentifier: String) async throws -> OpeningHoursEvaluation {
        if rawValue.range(of: #"\b(sunrise|sunset|dawn|dusk)\b"#, options: .regularExpression) != nil,
           coordinate == nil { throw OpeningHoursFailure.locationUnavailable }
        let context = try javascriptContext()
        guard let timeZone = TimeZone(identifier: systemTimeZoneIdentifier) else {
            throw OpeningHoursFailure.timeZoneUnavailable
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let localCalendar = calendar
        // Keep real instants in JavaScript. Only local Date operations use the POI's
        // calendar, including DST transitions and SunCalc's local solar event times.
        let parts: @convention(block) (Double) -> NSArray = { milliseconds in
            guard milliseconds.isFinite else { return [] }
            let date = Date(timeIntervalSince1970: milliseconds / 1_000)
            let c = localCalendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second, .nanosecond], from: date)
            return [c.year ?? 0, (c.month ?? 1) - 1, c.day ?? 1, c.hour ?? 0,
                    c.minute ?? 0, c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000,
                    (c.weekday ?? 1) - 1, -timeZone.secondsFromGMT(for: date) / 60] as NSArray
        }
        let instant: @convention(block) (NSArray) -> Double = { values in
            guard values.count == 7, let numbers = values as? [Double],
                  numbers.allSatisfy({ $0.isFinite && abs($0) < 10_000_000 }) else { return .nan }
            var c = DateComponents()
            c.year = Int(numbers[0]); c.month = Int(numbers[1]) + 1; c.day = Int(numbers[2])
            c.hour = Int(numbers[3]); c.minute = Int(numbers[4]); c.second = Int(numbers[5])
            c.nanosecond = Int(numbers[6]) * 1_000_000
            return localCalendar.date(from: c).map { $0.timeIntervalSince1970 * 1_000 } ?? .nan
        }
        context.exception = nil
        context.setObject(parts, forKeyedSubscript: "__naviLocalDateParts" as NSString)
        context.setObject(instant, forKeyedSubscript: "__naviLocalDateInstant" as NSString)
        var input: [String: Any] = [
            "raw": rawValue,
            "now": nowMilliseconds,
            "weekRanges": weekRanges,
            "systemTimeZone": systemTimeZoneIdentifier
        ]
        var location: [String: Any] = [:]
        if let coordinate {
            // opening_hours.js expects Nominatim's string-valued lat/lon.
            // Numeric values silently fall back to fixed 06:00/18:00 solar hours.
            location["lat"] = String(coordinate.latitude)
            location["lon"] = String(coordinate.longitude)
        }
        if let countryCode, countryCode.count == 2 {
            location["address"] = ["country_code": countryCode.lowercased(), "state": ""]
        }
        input["location"] = location
        context.setObject(input, forKeyedSubscript: "__naviOpeningHoursInput" as NSString)
        guard let json = context.evaluateScript(
            "JSON.stringify(__naviParseOpeningHours(__naviOpeningHoursInput))")?.toString(),
              let data = json.data(using: .utf8) else {
            throw OpeningHoursFailure.invalidExpression
        }
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           payload["error"] != nil {
            throw OpeningHoursFailure.invalidExpression
        }
        do {
            return try JSONDecoder().decode(OpeningHoursEvaluation.self, from: data)
        } catch {
            throw OpeningHoursFailure.invalidExpression
        }
    }

    private func javascriptContext() throws -> JSContext {
        if didLoadContext {
            guard let context else { throw OpeningHoursFailure.runtimeUnavailable }
            return context
        }
        didLoadContext = true
        guard let context = JSContext(),
              let sunCalc = Self.script(named: "suncalc"),
              let openingHours = Self.script(named: "opening_hours") else {
            throw OpeningHoursFailure.runtimeUnavailable
        }
        context.evaluateScript(Self.zonedDate)
        context.evaluateScript(sunCalc)
        context.evaluateScript(openingHours)
        context.evaluateScript(Self.wrapper)
        guard context.exception == nil,
              context.evaluateScript("typeof opening_hours === 'function'")?.toBool() == true else {
            throw OpeningHoursFailure.runtimeUnavailable
        }
        self.context = context
        return context
    }

    private static func script(named name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: "js",
                                  subdirectory: resourceSubdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: "js")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // opening_hours.js uses the local Date API, which JavaScriptCore otherwise
    // binds to the device zone. Foundation supplies calendar conversion, without
    // changing the process time zone or using fixed UTC offsets.
    private static let zonedDate = #"""
    (() => {
        const NativeDate = globalThis.Date;
        class PlaceDate extends NativeDate {
            constructor(...args) {
                if (args.length < 2) { super(...args); }
                else {
                    const p = [args[0], args[1], args.length > 2 ? args[2] : 1,
                        args[3] || 0, args[4] || 0, args[5] || 0, args[6] || 0];
                    if (p[0] >= 0 && p[0] <= 99) p[0] += 1900;
                    super(__naviLocalDateInstant(p));
                }
            }
            parts() {
                const t = this.getTime();
                if (this._partsTime !== t) {
                    this._parts = __naviLocalDateParts(t);
                    this._partsTime = t;
                }
                return this._parts || [];
            }
            getFullYear() { return this.parts()[0]; }
            getYear() { return this.getFullYear() - 1900; }
            getMonth() { return this.parts()[1]; }
            getDate() { return this.parts()[2]; }
            getHours() { return this.parts()[3]; }
            getMinutes() { return this.parts()[4]; }
            getSeconds() { return this.parts()[5]; }
            getMilliseconds() { return this.parts()[6]; }
            getDay() { return this.parts()[7]; }
            getTimezoneOffset() { return this.parts()[8]; }
            update(index, args) {
                const p = this.parts().slice(0, 7);
                args.forEach((v, i) => { p[index + i] = Number(v); });
                return this.setTime(__naviLocalDateInstant(p));
            }
            setFullYear(...v) { return this.update(0, v); }
            setMonth(...v) { return this.update(1, v); }
            setDate(...v) { return this.update(2, v); }
            setHours(...v) { return this.update(3, v); }
            setMinutes(...v) { return this.update(4, v); }
            setSeconds(...v) { return this.update(5, v); }
            setMilliseconds(...v) { return this.update(6, v); }
        }
        globalThis.Date = PlaceDate;
    })();
    """#

    private static let wrapper = #"""
    globalThis.__naviParseOpeningHours = function(input) {
        try {
            const hours = new opening_hours(input.raw, input.location || {});
            const now = new Date(input.now);
            let next = null;
            try {
                next = hours.getNextChange(now, new Date(input.now + 14 * 24 * 60 * 60 * 1000));
                if (next && next.getTime() <= input.now) next = null;
            } catch (_) {
                // A repeated local hour can be evaluated even when the library's
                // forward iterator cannot represent its next transition safely.
            }
            const nextOpen = next ? hours.getState(new Date(next.getTime() + 1000)) : null;
            const nextUnknown = next ? hours.getUnknown(new Date(next.getTime() + 1000)) : false;
            const days = input.weekRanges.map(function(range) {
                const from = new Date(range[0]);
                const to = new Date(range[1]);
                const intervals = hours.getOpenIntervals(from, to);
                return intervals.map(function(interval) {
                    return {
                        start: interval[0].getTime(),
                        end: interval[1].getTime(),
                        unknown: interval[2],
                        clippedStart: interval[0].getTime() <= from.getTime(),
                        clippedEnd: interval[1].getTime() >= to.getTime()
                    };
                });
            });
            return {
                open: hours.getState(now),
                unknown: hours.getUnknown(now),
                nextChange: next ? next.getTime() : null,
                nextOpen: nextOpen,
                nextUnknown: nextUnknown,
                days: days
            };
        } catch (error) {
            return { error: String(error) };
        }
    };
    """#
}
