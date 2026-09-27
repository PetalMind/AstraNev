import Foundation

nonisolated enum GTFSDate {
    private static let serviceTimeZone = TimeZone(identifier: "Europe/Warsaw")!

    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Warsaw")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Warsaw")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: value)
    }

    /// GTFS service times are offsets from noon minus twelve elapsed hours.
    /// Using local midnight plus seconds shifts trips by an hour on DST days.
    static func serviceStart(from value: String) -> Date? {
        guard let localDate = date(from: value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = serviceTimeZone
        let day = calendar.dateComponents([.year, .month, .day], from: localDate)
        var noonComponents = DateComponents()
        noonComponents.calendar = calendar
        noonComponents.timeZone = serviceTimeZone
        noonComponents.year = day.year
        noonComponents.month = day.month
        noonComponents.day = day.day
        noonComponents.hour = 12
        guard let noon = calendar.date(from: noonComponents) else { return nil }
        return noon.addingTimeInterval(-12 * 60 * 60)
    }

    static func serviceInstant(from serviceDate: String, seconds: Int) -> Date? {
        serviceStart(from: serviceDate)?.addingTimeInterval(TimeInterval(seconds))
    }

    static func serviceSeconds(at instant: Date, for serviceDate: String) -> TimeInterval? {
        guard let start = serviceStart(from: serviceDate) else { return nil }
        return instant.timeIntervalSince(start)
    }

    static func weekdayKey(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.weekday, from: date) {
        case 2: "monday"
        case 3: "tuesday"
        case 4: "wednesday"
        case 5: "thursday"
        case 6: "friday"
        case 7: "saturday"
        default: "sunday"
        }
    }
}
