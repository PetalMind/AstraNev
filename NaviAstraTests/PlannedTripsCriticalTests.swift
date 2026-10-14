import Foundation
import UserNotifications
import Testing
@testable import NaviAstra

/// Critical scheduling and local persistence regressions; no UI or simple control tests.
@MainActor struct PlannedTripsCriticalTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func trip(target: Date) -> PlannedTrip {
        var trip = PlannedTrip(origin: Destination(name: "Dom", coordinate: .init(latitude: 52, longitude: 21)),
            destination: Destination(name: "Cel", coordinate: .init(latitude: 52.1, longitude: 21.1)),
            transportMode: .car, preferences: RoutingPreferences(), targetDate: target)
        trip.timeZoneIdentifier = "Europe/Warsaw"
        return trip
    }
    private var route: NavigationRoute {
        NavigationRoute(coordinates: [.init(latitude: 52, longitude: 21), .init(latitude: 52.1, longitude: 21.1)],
            distance: 15_000, expectedTravelTime: 3_600, maneuvers: [])
    }

    @Test func arrivalDeadlineSubtractsMeasuredDurationBufferAndStopsOnce() {
        let target = date("2026-10-14T08:00:00Z")
        var trip = trip(target: target)
        trip.timing = .arrival; trip.bufferMinutes = 15; trip.stopMinutes = 10
        let estimate = trip.makeEstimate(for: target, route: route, travelSeconds: 4_200,
            currentTraffic: true, matched: true)
        #expect(estimate.departure == target.addingTimeInterval(-5_700))
        #expect(estimate.arrival == target.addingTimeInterval(-900))
        #expect(estimate.currentTraffic)
        trip.estimate = estimate
        #expect(trip.departure(for: target) == estimate.departure)
        trip.timing = .departure
        let fixed = trip.makeEstimate(for: target, route: route, travelSeconds: 4_200,
            currentTraffic: false, matched: true)
        #expect(fixed.departure == target)
        #expect(fixed.arrival == target.addingTimeInterval(4_800))
    }

    @Test func regularTripsPreserveWallClockAcrossDSTAndSkipCompletedOccurrence() {
        var trip = trip(target: date("2026-10-24T06:00:00Z")) // 08:00 CEST
        trip.repeatRule = .daily
        let dates = trip.occurrences(after: date("2026-10-24T00:00:00Z"), days: 3)
        #expect(dates.count == 3)
        #expect(dates[1] == date("2026-10-25T07:00:00Z")) // 08:00 CET
        #expect(dates.allSatisfy { trip.calendar.component(.hour, from: $0) == 8 })
        trip.completedOccurrence = dates[0]
        #expect(trip.occurrences(after: date("2026-10-24T00:00:00Z"), days: 3).first == dates[1])
        trip.repeatRule = .workdays
        #expect(trip.occurrences(after: date("2026-10-24T00:00:00Z"), days: 3).first == date("2026-10-26T07:00:00Z"))
        trip.repeatRule = .custom; trip.weekdays = [1]
        #expect(trip.occurrences(after: date("2026-10-24T00:00:00Z"), days: 3) == [date("2026-10-25T07:00:00Z")])
    }

    @Test func unavailableETAOrFutureTransitTimetableCannotInventDeparture() {
        let target = date("2026-10-14T08:00:00Z")
        var trip = trip(target: target); trip.timing = .arrival
        #expect(trip.departure(for: target) == nil)
        trip.estimate = trip.makeEstimate(for: target, route: route, travelSeconds: 3_600,
            currentTraffic: false, matched: false)
        #expect(trip.departure(for: target) == target.addingTimeInterval(-4_500))
        trip.transportMode = .transit
        #expect(trip.departure(for: target.addingTimeInterval(86_400)) == nil)
        let changed = NavigationRoute(coordinates: [.init(latitude: 50, longitude: 19), .init(latitude: 50.1, longitude: 19.1)],
            distance: 15_000, expectedTravelTime: 3_600, maneuvers: [])
        trip.preferredRoute = PlannedTrip.fingerprint(route)
        #expect(!trip.preferredOption(in: [changed]).matched)
        #expect(trip.preferredOption(in: [changed]).route?.id == changed.id)
        #expect(trip.preferredOption(in: [changed, route]).route?.id == route.id)
    }

    @Test func intentAndRecurrenceSurviveLocalReloadAndCorruptFileIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planned-critical-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripPlanningService(directory: directory)
        var trip = trip(target: date("2026-10-14T08:00:00Z"))
        trip.repeatRule = .custom; trip.weekdays = [2, 4, 6]
        trip.waypoints = [Destination(name: "Postój", coordinate: .init(latitude: 52.05, longitude: 21.05))]
        trip.preferences.avoidTolls = true
        trip.preferredRoute = PlannedTrip.fingerprint(route)
        #expect(store.save(trip))
        #expect(TripPlanningService(directory: directory).trips == [trip])
        let file = directory.appendingPathComponent("planned-trips.json")
        let damaged = Data("corrupt-local-data".utf8)
        try damaged.write(to: file)
        let recovered = TripPlanningService(directory: directory)
        #expect(recovered.errorMessage != nil)
        #expect(!recovered.save(trip))
        #expect(try Data(contentsOf: file) == damaged)
    }
    @Test func editedDepartureReplacesStableReminderIDsAndDropsExpiredAlerts() {
        let target = date("2026-10-14T08:00:00Z")
        let now = target.addingTimeInterval(-7_200)
        var trip = trip(target: target)
        trip.timing = .arrival
        trip.reminderMinutes = [60, 15, 0]
        trip.estimate = trip.makeEstimate(for: target, route: route, travelSeconds: 3_600,
            currentTraffic: false, matched: true)
        let scheduler = TripReminderScheduler()
        let before = scheduler.requests(for: [trip], now: now)
        #expect(before.count == 2) // The hour-before alert is already in the past.
        #expect(Set(before.map { $0.1.identifier }).count == before.count)
        trip.estimate = trip.makeEstimate(for: target, route: route, travelSeconds: 4_200,
            currentTraffic: true, matched: true)
        let after = scheduler.requests(for: [trip], now: now)
        #expect(before.map { $0.1.identifier } == after.map { $0.1.identifier })
        #expect(zip(before, after).allSatisfy { $0.1.0 == $0.0.0.addingTimeInterval(-600) })
        #expect(scheduler.requests(for: [trip], now: target).isEmpty)
        #expect(scheduler.requests(for: [], now: now).isEmpty)
    }

}
