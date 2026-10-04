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
        let context = try javascriptContext()
        var input: [String: Any] = [
            "raw": rawValue,
            "now": nowMilliseconds,
            "weekRanges": weekRanges,
            "systemTimeZone": systemTimeZoneIdentifier
        ]
        if let coordinate {
            var location: [String: Any] = ["lat": coordinate.latitude, "lon": coordinate.longitude]
            if let countryCode, countryCode.count == 2 {
                location["address"] = ["country_code": countryCode.lowercased(), "state": ""]
            }
            input["location"] = location
        }
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

    private static let wrapper = #"""
    globalThis.__naviParseOpeningHours = function(input) {
        try {
            const hours = new opening_hours(input.raw, input.location || null);
            const now = new Date(input.now);
            const next = hours.getNextChange(now, new Date(input.now + 14 * 24 * 60 * 60 * 1000));
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
