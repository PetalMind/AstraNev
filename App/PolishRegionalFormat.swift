import Foundation

/// Presentation uses Polish conventions; dates retain their actual time zone.
nonisolated enum PolishRegionalFormat {
    static let locale = Locale(identifier: "pl_PL")

    static func dateTime(_ date: Date,
                         dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                         timeStyle: Date.FormatStyle.TimeStyle = .shortened,
                         timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        dateTime(date, dateStyle: .omitted, timeZone: timeZone)
    }

    static func weekday(_ day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard (1...7).contains(day) else { return "" }
        return calendar.weekdaySymbols[day - 1].localizedCapitalized(with: locale)
    }
}
