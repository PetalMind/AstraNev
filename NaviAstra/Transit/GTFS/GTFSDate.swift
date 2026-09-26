import Foundation

nonisolated enum GTFSDate {
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
