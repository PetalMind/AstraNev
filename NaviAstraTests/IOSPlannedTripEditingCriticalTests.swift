#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor struct IOSPlannedTripEditingCriticalTests {
    private func place(_ index: Int) -> Destination {
        Destination(name: "Punkt \(index)", coordinate: .init(latitude: 52 + Double(index) * 0.01, longitude: 21))
    }
    private func draft() -> IOSPlannedTripDraft {
        IOSPlannedTripDraft(seed: PlannedTrip(origin: place(0), destination: place(10), transportMode: .car,
            preferences: RoutingPreferences(), targetDate: Date().addingTimeInterval(86_400)),
            currentOrigin: nil, initialCenter: nil, preferences: RoutingPreferences())
    }
    private func option(_ seconds: Double, via: Bool = false) -> NavigationRoute {
        NavigationRoute(coordinates: via ? [place(0).coordinate, .init(latitude: 52.05, longitude: 21.03), place(10).coordinate]
            : [place(0).coordinate, place(10).coordinate], distance: 12_000,
            expectedTravelTime: seconds, maneuvers: [])
    }
    private func prepare(_ draft: IOSPlannedTripDraft, options: [NavigationRoute]) {
        draft.mapState.destination = draft.destination
        draft.mapState.routeOrigin = RoutePoint(draft.origin!, source: .savedPlace)
        draft.mapState.routeOptions = options
        draft.select(options[0])
    }

    @Test func transportChangesPreserveIntentAndWaypointsInsteadOfDeletingUserData() {
        let draft = draft()
        #expect(draft.choose(place(3), for: .waypoint))
        draft.stopMinutes = 20; draft.timing = .arrival
        let stops = draft.waypoints
        draft.mode = .transit
        #expect(draft.waypoints == stops)
        #expect(draft.stopMinutes == 20)
        #expect(draft.validationMessage != nil)
        draft.mode = .parkRide
        #expect(draft.timing == .arrival)
        #expect(draft.validationMessage != nil)
        draft.mode = .car
        #expect(draft.validationMessage == nil)
        #expect(draft.waypoints == stops)
        #expect(draft.plan?.waypoints == stops)
    }

    @Test func selectedVariantIsStableUntilActualRoutingInputChangesAndETAKeepsCalculationTimestamp() {
        let draft = draft(), fast = option(1_200), alternative = option(1_600, via: true)
        prepare(draft, options: [fast, alternative])
        let key = draft.previewKey, calculatedAt = draft.previewCalculatedAt
        #expect(draft.hasPreview)
        draft.select(alternative)
        #expect(draft.previewKey == key)
        #expect(draft.hasPreview)
        #expect(draft.mapState.route?.id == alternative.id)
        #expect(draft.estimate?.travelSeconds == 1_600)
        #expect(draft.estimate?.updatedAt == calculatedAt)
        draft.title = "Praca"; draft.reminders = [60]
        #expect(draft.hasPreview)
        draft.targetDate = draft.targetDate.addingTimeInterval(60)
        #expect(!draft.hasPreview)
        #expect(draft.estimate == nil)
    }

    @Test func replacingWaypointKeepsItsIdentityAndDuplicateAndLimitChecksPreserveTheExistingStops() {
        let draft = draft()
        for index in 1...8 { #expect(draft.choose(place(index), for: .waypoint)) }
        let original = draft.waypoints, id = original[3].id
        #expect(!draft.choose(place(9), for: .waypoint))
        #expect(!draft.choose(place(3), for: .waypoint))
        #expect(draft.waypoints == original)
        #expect(draft.choose(place(20), for: .replaceWaypoint(id)))
        #expect(draft.waypoints.count == 8)
        #expect(draft.waypoints[3].id == id)
        #expect(draft.waypoints[3].coordinate == place(20).coordinate)
    }

    @Test func stalePreviewCannotBeSavedAsAComputedRoute() async {
        let draft = draft(), route = option(1_200)
        prepare(draft, options: [route])
        #expect(draft.hasPreview)
        draft.bufferMinutes += 5
        #expect(!draft.hasPreview)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-trip-editing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TripPlanningService(directory: directory)
        let saved = await draft.save(to: service, withoutRoute: false)
        #expect(!saved)
        #expect(service.trips.isEmpty)
        #expect(draft.savedTrip == nil)
    }

    @Test func minutePrecisionPreservesTheFirstDayOfARegularTrip() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let target = calendar.date(bySettingHour: 8, minute: 15, second: 45, of: tomorrow)!
        var seed = PlannedTrip(origin: place(0), destination: place(10), transportMode: .car,
            preferences: RoutingPreferences(), targetDate: target, timeZoneIdentifier: "Europe/Warsaw")
        seed.repeatRule = .daily
        let draft = IOSPlannedTripDraft(seed: seed, currentOrigin: nil, initialCenter: nil, preferences: RoutingPreferences())
        let expected = calendar.dateInterval(of: .minute, for: target)!.start
        #expect(draft.plan?.targetDate == expected)
        #expect(draft.plan?.occurrences(after: Date()).first == expected)
        #expect(calendar.component(.second, from: draft.targetDate) == 0)
    }

    @Test func selectedMapPOIKeepsItsMetadataThroughCameraAnimationUntilTheUserMovesTheMap() {
        let draft = draft()
        var poi = place(2)
        poi.poi = POIMetadata(provider: .openStreetMap, osmID: "node/123", category: "parking", brand: nil, operatorName: nil)
        draft.selectMapPlace(poi)
        draft.updateMapCandidate(place(7).coordinate)
        #expect(draft.mapCandidate == poi)
        draft.mapGestureStarted()
        let moved = Coordinate(latitude: poi.coordinate.latitude + 0.00002, longitude: poi.coordinate.longitude)
        draft.updateMapCandidate(moved)
        #expect(draft.mapCandidate?.coordinate == moved)
        #expect(draft.mapCandidate?.poi == nil)
        draft.cancel()
    }
}
#endif
