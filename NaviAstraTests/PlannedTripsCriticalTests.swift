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
        trip.preferences.transit = .init(profile: .leastWalking, additionalTransferBufferMinutes: 6,
                                         pedestrianProfile: .wheelchair)
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

    @Test func olderPlansKeepDefaultTransitPreferencesAndPartialPreferencesDecodeSafely() throws {
        let legacy = try JSONDecoder().decode(RoutingPreferences.self, from: Data("{}".utf8))
        #expect(legacy.transit == TransitRoutePreferences())
        let partial = try JSONDecoder().decode(RoutingPreferences.self,
            from: Data("{\"transit\":{\"profile\":\"fewestTransfers\"}}".utf8))
        #expect(partial.transit.profile == .fewestTransfers)
        #expect(partial.transit.additionalTransferBufferMinutes == 1)
        #expect(partial.transit.pedestrianProfile == .foot)
    }

    @Test func measuredTrafficChangesSavedVariantOnlyForASubstantialImprovement() {
        var trip = trip(target: Date().addingTimeInterval(3_600))
        let preferred = route
        let alternative = NavigationRoute(coordinates: [preferred.coordinates[0],
            .init(latitude: 52.05, longitude: 21.08), preferred.coordinates[1]],
            distance: 16_000, expectedTravelTime: 3_500, maneuvers: [])
        trip.preferredRoute = PlannedTrip.fingerprint(preferred)
        let ordered = [alternative, preferred]
        #expect(trip.preferredOption(in: ordered, measuredTravelTimes: [
            preferred.id: 3_600, alternative.id: 3_300]).route?.id == preferred.id)
        let faster = trip.preferredOption(in: ordered, measuredTravelTimes: [
            preferred.id: 3_600, alternative.id: 3_200])
        #expect(faster.route?.id == alternative.id)
        #expect(!faster.matched)
        #expect(trip.preferredOption(in: ordered, measuredTravelTimes: [
            preferred.id: 1_000, alternative.id: 890]).route?.id == preferred.id)
        #expect(trip.preferredOption(in: ordered).route?.id == preferred.id)
    }

    @Test func plannedTripFindsClosureDetourEvenWhenFlowCoverageIsUnavailable() async throws {
        let start = Coordinate(latitude: 52, longitude: 21), end = Coordinate(latitude: 52.01, longitude: 21)
        let blocked = NavigationRoute(coordinates: [start, end], distance: 1_112, expectedTravelTime: 200, maneuvers: [])
        let detour = NavigationRoute(coordinates: [start, .init(latitude: 52.002, longitude: 21.002),
            .init(latitude: 52.008, longitude: 21.002), end], distance: 1_500, expectedTravelTime: 300, maneuvers: [])
        let routes = PlannedClosureRouteProvider(blocked: blocked, detour: detour)
        let live = NavigationSessionDependencies.live(routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil)
        let traffic = PlannedClosureTrafficProvider(closure: TrafficIncident(id: "closed", description: "Droga zamknięta",
            coordinate: .init(latitude: 52.003, longitude: 21), delaySeconds: nil,
            category: .roadClosed, severity: .major,
            geometry: [.init(latitude: 52.003, longitude: 21), .init(latitude: 52.007, longitude: 21)]))
        let dependencies = NavigationSessionDependencies(routeProvider: routes, transitProvider: live.transitProvider,
            transitDataProvider: live.transitDataProvider, speedLimitProvider: live.speedLimitProvider,
            roadDataProvider: live.roadDataProvider, trafficProvider: traffic,
            trafficProviderFactory: live.trafficProviderFactory, voiceGuidance: live.voiceGuidance)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planned-closure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TripPlanningService(directory: directory, routingDependencies: dependencies)
        var plan = PlannedTrip(origin: Destination(name: "Start", coordinate: start),
            destination: Destination(name: "Cel", coordinate: end), transportMode: .car,
            preferences: RoutingPreferences(), targetDate: Date().addingTimeInterval(600))
        plan.preferredRoute = PlannedTrip.fingerprint(blocked)
        let (selected, matched) = try await service.calculate(plan, occurrence: plan.targetDate, now: true)
        #expect(selected.id == detour.id)
        #expect(!matched)
        #expect(routes.requestCount == 2)
        #expect(routes.receivedExclusion)
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

@MainActor private final class PlannedClosureRouteProvider: RouteProvider {
    let blocked: NavigationRoute
    let detour: NavigationRoute
    private(set) var requestCount = 0
    private(set) var receivedExclusion = false

    init(blocked: NavigationRoute, detour: NavigationRoute) {
        self.blocked = blocked
        self.detour = detour
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        requestCount += 1
        receivedExclusion = !RoadRoutingContext.closurePolygons.isEmpty
        return receivedExclusion ? [detour] : [blocked]
    }
}

private struct PlannedClosureTrafficProvider: TrafficProvider {
    let closure: TrafficIncident
    func snapshot(near: Coordinate, incidentRadiusMeters: Double) async throws -> TrafficSnapshot {
        TrafficSnapshot(flow: nil, incidents: [closure], updatedAt: .now,
                        partialError: nil, incidentDataAvailable: true)
    }
    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] { [closure] }
    func routeFlowSamples(at queries: [RouteTrafficFlowQuery]) async -> [RouteTrafficFlowSample] { [] }
    func rasterFlowTileURLTemplate(style: TrafficTileStyle) -> String? { nil }
    func rasterIncidentTileURLTemplate(style: TrafficTileStyle) -> String? { nil }
}
