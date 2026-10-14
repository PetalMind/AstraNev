import Foundation

/// The saved intent is independent of a route response and its expiring ETA.
struct PlannedTrip: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var origin: Destination
    var destination: Destination
    var waypoints: [Destination] = []
    var transportMode: TransportMode
    var preferences: RoutingPreferences
    var timing: Timing = .departure
    var targetDate: Date
    var timeZoneIdentifier = TimeZone.current.identifier
    var bufferMinutes = 15
    var stopMinutes = 0
    var repeatRule: RepeatRule = .never
    var weekdays: Set<Int> = [] // Calendar weekday: Sunday = 1.
    var reminderMinutes: Set<Int> = [15, 0]
    var preferredRoute: [Coordinate] = []
    var createdAt = Date()
    var completedOccurrence: Date?
    var estimate: Estimate?
    var refreshError: String?

    enum Timing: String, Codable, CaseIterable, Identifiable {
        case departure, arrival
        var id: Self { self }
        var title: String { self == .departure ? "Wyjazd" : "Przyjazd do" }
    }
    enum RepeatRule: String, Codable, CaseIterable, Identifiable {
        case never, daily, workdays, weekly, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .never: "Nigdy"
            case .daily: "Codziennie"
            case .workdays: "Dni robocze"
            case .weekly: "Co tydzień"
            case .custom: "Wybrane dni"
            }
        }
    }
    struct Estimate: Codable, Equatable {
        var occurrence: Date
        var departure: Date
        var arrival: Date
        var travelSeconds: TimeInterval
        var distanceMeters: Double
        var updatedAt: Date
        var currentTraffic: Bool
        var preferredRouteMatched: Bool
        var trafficNote: String?
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? destination.name : title }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    func occurrences(after now: Date, days: Int = 30) -> [Date] {
        if repeatRule == .never {
            return targetDate > now && completedOccurrence != targetDate ? [targetDate] : []
        }
        let calendar = calendar
        let clock = calendar.dateComponents([.hour, .minute], from: targetDate)
        let originalWeekday = calendar.component(.weekday, from: targetDate)
        let start = calendar.startOfDay(for: max(now, targetDate))
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            let matches: Bool = switch repeatRule {
            case .never: false
            case .daily: true
            case .workdays: (2...6).contains(weekday)
            case .weekly: weekday == originalWeekday
            case .custom: weekdays.contains(weekday)
            }
            guard matches, let date = calendar.date(bySettingHour: clock.hour ?? 0,
                minute: clock.minute ?? 0, second: 0, of: day,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                date >= targetDate, date > now, date != completedOccurrence else { return nil }
            return date
        }
    }

    func departure(for occurrence: Date) -> Date? {
        if let estimate, estimate.occurrence == occurrence { return estimate.departure }
        if timing == .departure { return occurrence }
        guard let estimate else { return nil }
        if transportMode == .transit || transportMode == .parkRide { return nil }
        // Future recurring reminders explicitly refer to the last calculation.
        return occurrence.addingTimeInterval(-estimate.travelSeconds - Double(bufferMinutes + stopMinutes) * 60)
    }

    func makeEstimate(for occurrence: Date, route: NavigationRoute, travelSeconds: TimeInterval,
                      currentTraffic: Bool, matched: Bool, trafficNote: String? = nil,
                      updatedAt: Date = Date()) -> Estimate {
        let extra = Double(stopMinutes) * 60
        let arrival = timing == .arrival
            ? route.journey?.arrival ?? occurrence.addingTimeInterval(-Double(bufferMinutes) * 60)
            : route.journey?.arrival ?? occurrence.addingTimeInterval(travelSeconds + extra)
        let departure = timing == .arrival
            ? route.journey?.departure ?? occurrence.addingTimeInterval(-Double(bufferMinutes) * 60 - travelSeconds - extra)
            : route.journey?.departure ?? occurrence
        return Estimate(occurrence: occurrence, departure: departure, arrival: arrival,
            travelSeconds: travelSeconds, distanceMeters: route.distance, updatedAt: updatedAt,
            currentTraffic: currentTraffic, preferredRouteMatched: matched, trafficNote: trafficNote)
    }

    static func fingerprint(_ route: NavigationRoute) -> [Coordinate] {
        let geometry = RouteProgressGeometry(route)
        guard geometry.length > 0 else { return [] }
        return (1..<25).compactMap { geometry.coordinate(at: geometry.length * Double($0) / 25) }
    }

    func preferredOption(in routes: [NavigationRoute]) -> (route: NavigationRoute?, matched: Bool) {
        guard !preferredRoute.isEmpty else { return (routes.first, true) }
        let scores = routes.map { route in
            let geometry = RouteProgressGeometry(route)
            let hits = preferredRoute.filter { (geometry.project($0)?.distanceFromRoute ?? .infinity) < 150 }.count
            return (route, Double(hits) / Double(preferredRoute.count))
        }
        if let best = scores.max(by: { $0.1 < $1.1 }), best.1 >= 0.8 { return (best.0, true) }
        return (routes.first, false)
    }
}
