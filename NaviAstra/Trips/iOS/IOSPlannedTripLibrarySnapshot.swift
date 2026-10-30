#if os(iOS)
import Foundation

/// Compute each next occurrence once, using one clock value for the whole list.
struct IOSPlannedTripLibrarySnapshot {
    struct Entry: Identifiable {
        let trip: PlannedTrip
        let occurrence: Date?
        var id: UUID { trip.id }
    }

    struct Day: Hashable {
        let start: Date
        let timeZoneIdentifier: String
    }

    struct Section: Identifiable {
        let id: Day
        let title: String
        let entries: [Entry]
    }

    let sections: [Section]
    let regular: [Entry]
    let past: [Entry]

    init(trips: [PlannedTrip], now: Date) {
        let entries = trips.map { Entry(trip: $0, occurrence: $0.occurrences(after: now).first) }
        let upcoming = entries.filter { $0.occurrence != nil }.sorted {
            ($0.occurrence ?? .distantFuture) < ($1.occurrence ?? .distantFuture)
        }
        let grouped = Dictionary(grouping: upcoming) { entry in
            Day(start: entry.trip.calendar.startOfDay(for: entry.occurrence ?? entry.trip.targetDate),
                timeZoneIdentifier: entry.trip.calendar.timeZone.identifier)
        }
        sections = grouped.map { day, values in
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = PolishRegionalFormat.locale
            calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
            let title: String
            if calendar.isDate(day.start, inSameDayAs: now) {
                title = "Dzisiaj"
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                      calendar.isDate(day.start, inSameDayAs: tomorrow) {
                title = "Jutro"
            } else {
                title = PolishRegionalFormat.dateTime(day.start, dateStyle: .complete, timeStyle: .omitted,
                    timeZone: calendar.timeZone)
            }
            let zone = calendar.timeZone == .current ? "" : " · " +
                (calendar.timeZone.localizedName(for: .generic, locale: PolishRegionalFormat.locale)
                    ?? calendar.timeZone.identifier)
            return Section(id: day, title: title + zone, entries: values)
        }.sorted {
            ($0.entries.first?.occurrence ?? .distantFuture) < ($1.entries.first?.occurrence ?? .distantFuture)
        }
        regular = entries.filter { $0.trip.repeatRule != .never }.sorted {
            $0.trip.displayTitle.compare($1.trip.displayTitle, options: [.caseInsensitive, .numeric],
                locale: PolishRegionalFormat.locale) == .orderedAscending
        }
        past = entries.filter { $0.occurrence == nil }.sorted { $0.trip.targetDate > $1.trip.targetDate }
    }

    static func scheduleTitle(_ trip: PlannedTrip) -> String {
        if trip.repeatRule == .custom {
            return [2, 3, 4, 5, 6, 7, 1].filter { trip.weekdays.contains($0) }
                .map { String(PolishRegionalFormat.weekday($0).prefix(3)) }.joined(separator: ", ")
        }
        if trip.repeatRule == .weekly {
            return "Co tydzień · " + PolishRegionalFormat.weekday(trip.calendar.component(.weekday, from: trip.targetDate))
        }
        return trip.repeatRule.title
    }
}
#endif
