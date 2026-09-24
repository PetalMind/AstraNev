import Foundation
import JavaScriptCore

struct PlaceOpeningHours {
    let rawValue: String
    let coordinate: Coordinate?
    let countryCode: String?
    let timeZoneIdentifier: String?

    init(rawValue: String, coordinate: Coordinate? = nil,
         countryCode: String? = nil, timeZoneIdentifier: String? = nil) {
        self.rawValue = rawValue
        self.coordinate = coordinate
        self.countryCode = countryCode
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    func isOpen(at date: Date = Date(), calendar: Calendar = .current) -> Bool? {
        guard let result = evaluate(at: date, calendar: calendar), !result.unknown else { return nil }
        return result.open
    }

    func statusText(at date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let result = evaluate(at: date, calendar: calendar), !result.unknown else { return nil }
        guard result.open else { return "Zamknięte teraz" }
        guard let nextChange = result.nextChange,
              !result.nextUnknown,
              result.nextOpen == false else { return "Otwarte teraz" }
        return "Otwarte · zamyka o \(Self.clockTimeString(nextChange, calendar: targetCalendar(from: calendar)))"
    }

    func closingTime(at date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let result = evaluate(at: date, calendar: calendar), result.open, !result.unknown,
              !result.nextUnknown, result.nextOpen == false else { return nil }
        return result.nextChange
    }

    var weeklyRows: [(String, String)]? {
        weeklyRows(at: Date())
    }

    func weeklyRows(at date: Date, calendar: Calendar = .current) -> [(String, String)]? {
        guard let result = evaluate(at: date, calendar: calendar) else { return nil }
        let labels = ["Pon.", "Wt.", "Śr.", "Czw.", "Pt.", "Sob.", "Niedz."]
        return labels.enumerated().map { index, label in
            let intervals = index < result.days.count ? result.days[index] : []
            guard !intervals.isEmpty else { return (label, "Zamknięte") }
            let values = intervals.map { interval -> String in
                let start = Self.intervalTimeString(interval.start, calendar: .current, clippedStart: interval.clippedStart)
                let end = Self.intervalTimeString(interval.end, calendar: .current, clippedEnd: interval.clippedEnd)
                let value = "\(start)–\(end)"
                return interval.unknown ? "Niepewne · \(value)" : value
            }
            return (label, values.joined(separator: ", "))
        }
    }

    private func evaluate(at date: Date, calendar: Calendar) -> ParsedOpeningHours? {
        let localCalendar = targetCalendar(from: calendar)
        guard let parserDate = Self.parserDate(for: date, targetCalendar: localCalendar) else { return nil }
        var weekCalendar = localCalendar
        weekCalendar.firstWeekday = 2
        weekCalendar.minimumDaysInFirstWeek = 4
        guard let weekStart = weekCalendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        var dayRanges: [[Double]] = []
        for offset in 0..<7 {
            guard let start = weekCalendar.date(byAdding: .day, value: offset, to: weekStart),
                  let end = weekCalendar.date(byAdding: .day, value: offset + 1, to: weekStart),
                  let parserStart = Self.parserDate(for: start, targetCalendar: weekCalendar),
                  let parserEnd = Self.parserDate(for: end, targetCalendar: weekCalendar) else { return nil }
            dayRanges.append([parserStart.timeIntervalSince1970 * 1_000,
                              parserEnd.timeIntervalSince1970 * 1_000])
        }
        guard var result = OSMOpeningHoursRuntime.evaluate(
            rawValue: rawValue,
            nowMilliseconds: parserDate.timeIntervalSince1970 * 1_000,
            weekRanges: dayRanges,
            coordinate: coordinate,
            countryCode: countryCode,
            systemTimeZoneIdentifier: localCalendar.timeZone.identifier) else { return nil }
        if let parserDate = result.nextChange,
           let targetDate = Self.targetDate(fromParserDate: parserDate, calendar: localCalendar) {
            result.nextChangeMilliseconds = targetDate.timeIntervalSince1970 * 1_000
        }
        return result
    }

    private func targetCalendar(from fallback: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pl_PL")
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? fallback.timeZone
        return calendar
    }

    private static func parserDate(for date: Date, targetCalendar: Calendar) -> Date? {
        let components = targetCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var systemCalendar = Calendar(identifier: .gregorian)
        systemCalendar.timeZone = .current
        return systemCalendar.date(from: components)
    }

    private static func targetDate(fromParserDate date: Date, calendar: Calendar) -> Date? {
        var systemCalendar = Calendar(identifier: .gregorian)
        systemCalendar.timeZone = .current
        let components = systemCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return calendar.date(from: components)
    }

    private static func intervalTimeString(_ date: Date, calendar: Calendar,
                                          clippedStart: Bool = false, clippedEnd: Bool = false) -> String {
        if clippedStart { return "00:00" }
        if clippedEnd { return "24:00" }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func clockTimeString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? Locale(identifier: "pl_PL")
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    fileprivate struct ParsedInterval: Decodable {
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

    fileprivate struct ParsedOpeningHours: Decodable {
        let open: Bool
        let unknown: Bool
        var nextChangeMilliseconds: Double?
        let nextOpen: Bool?
        let nextUnknown: Bool
        let days: [[ParsedInterval]]

        var nextChange: Date? {
            guard let nextChangeMilliseconds else { return nil }
            return Date(timeIntervalSince1970: nextChangeMilliseconds / 1_000)
        }
    }
}

private enum OSMOpeningHoursRuntime {
    private static let lock = NSRecursiveLock()
    private static let context: JSContext? = {
        let context = JSContext()
        guard let context,
              let sunCalcURL = Bundle.main.url(forResource: "suncalc", withExtension: "js"),
              let openingHoursURL = Bundle.main.url(forResource: "opening_hours", withExtension: "js"),
              let sunCalc = try? String(contentsOf: sunCalcURL, encoding: .utf8),
              let openingHours = try? String(contentsOf: openingHoursURL, encoding: .utf8) else { return nil }
        context.evaluateScript(sunCalc)
        context.evaluateScript(openingHours)
        context.evaluateScript(Self.wrapper)
        guard context.exception == nil,
              context.evaluateScript("typeof opening_hours === 'function'")?.toBool() == true else { return nil }
        return context
    }()

    static func evaluate(rawValue: String, nowMilliseconds: Double, weekRanges: [[Double]],
                         coordinate: Coordinate?, countryCode: String?,
                         systemTimeZoneIdentifier: String) -> PlaceOpeningHours.ParsedOpeningHours? {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return nil }
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
        guard let json = context.evaluateScript("JSON.stringify(__naviParseOpeningHours(__naviOpeningHoursInput))")?.toString(),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlaceOpeningHours.ParsedOpeningHours.self, from: data)
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
