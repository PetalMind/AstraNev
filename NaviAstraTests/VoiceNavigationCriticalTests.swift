#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct VoiceNavigationCriticalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func rejectsStaleGPSInsteadOfRepeatingTurnBehindDriver() {
        let state = activeState()
        state.location?.timestamp = now.addingTimeInterval(-60)
        let response = VoiceNavigationActions.answer(.maneuver, state: state, now: now)
        #expect(response.contains("GPS"))
        #expect(!response.contains("prawo"))
    }

    @Test
    func rejectsProgressAndMapMatchingFromPreviousRoute() {
        let state = activeState()
        state.progress?.geometryRouteID = UUID()
        #expect(VoiceNavigationActions.answer(.maneuver, state: state, now: now).contains("nowej trasie"))
        state.progress?.geometryRouteID = state.route?.id
        state.routeMatch = nil
        #expect(VoiceNavigationActions.answer(.lanes, state: state, now: now).contains("dopasować"))
    }

    @Test
    func freshPositionCannotValidateOldMapMatch() {
        let state = activeState()
        state.location?.timestamp = now.addingTimeInterval(1)
        let response = VoiceNavigationActions.answer(.maneuver, state: state, now: now.addingTimeInterval(1))
        #expect(response.contains("dopasować"))
        #expect(!response.contains("prawo"))
    }

    @Test
    func reroutingDoesNotAnnounceOldManeuverOrETA() {
        let state = activeState()
        state.status = .rerouting
        for query in [VoiceQuery.maneuver, .arrival, .lanes] {
            #expect(VoiceNavigationActions.answer(query, state: state, now: now).contains("przeliczanie"))
        }
    }

    @Test
    func trafficIgnoresOtherRoutesBehindDriverAndExpiredMeasurements() throws {
        let state = activeState()
        let route = try #require(state.route)
        func segment(routeID: UUID, start: Double, end: Double, measuredAt: Date) -> RouteTrafficSegment {
            RouteTrafficSegment(id: UUID().uuidString, routeID: routeID,
                                startDistance: start, endDistance: end, coordinates: route.coordinates,
                                colorHex: 0, isRoadClosure: false, currentSpeedKph: 0,
                                freeFlowSpeedKph: 50, measuredAt: measuredAt)
        }
        state.traffic = TrafficSnapshot(flow: nil, incidents: [], routeFlowSegments: [
            segment(routeID: UUID(), start: 100, end: 900, measuredAt: now),
            segment(routeID: route.id, start: 0, end: 50, measuredAt: now),
            segment(routeID: route.id, start: 100, end: 900, measuredAt: now.addingTimeInterval(-600))
        ], updatedAt: now, partialError: nil, incidentDataAvailable: true)
        #expect(VoiceNavigationActions.answer(.traffic, state: state, now: now).contains("wystarczających pomiarów"))
        state.traffic = TrafficSnapshot(flow: nil, incidents: [], routeFlowSegments: [
            segment(routeID: route.id, start: 100, end: 900, measuredAt: now)
        ], updatedAt: now, partialError: nil, incidentDataAvailable: true)
        #expect(VoiceNavigationActions.answer(.traffic, state: state, now: now).contains("są spowolnienia"))
        #expect(VoiceNavigationActions.answer(.traffic, state: state, now: now.addingTimeInterval(600)).contains("GPS"))
    }

    @Test func approachingTrafficIsAnnouncedOnceWithDistanceEvenInConciseGuidance() throws {
        let route = try #require(activeState().route)
        let coordinate = try #require(route.coordinates.first)
        let voice = VoiceGuidanceEngine(preferences: .init(isEnabled: true, verbosity: .concise,
            voiceIdentifier: nil, speechRate: 0.5, volume: 1))
        for (category, label) in [(TrafficIncidentCategory.jam, "zaczyna się korek"),
                                  (.roadClosed, "droga jest zamknięta")] {
            let early = try #require(voice.trafficNotice(category, coordinate: coordinate, distance: 505, reportID: "odcinek"))
            let matched = Coordinate(latitude: coordinate.latitude + 0.0005, longitude: coordinate.longitude)
            let close = try #require(voice.trafficNotice(category, coordinate: matched, distance: 35, reportID: "odcinek"))
            #expect(early.text == "Za 505 metrów \(label).")
            #expect(close.text == "Za 35 metrów \(label).")
            #expect(early.key == close.key)
            #expect(voice.trafficNotice(category, coordinate: coordinate, distance: 200, reportID: "drugie-źródło")?.key == early.key)
            #expect(voice.trafficNotice(category, coordinate: coordinate, distance: -2) == nil)
        }
        voice.setEnabled(false)
        #expect(voice.trafficNotice(.jam, coordinate: coordinate, distance: 300) == nil)

        func segment(_ start: Double, _ end: Double, id: UUID, date: Date, closed: Bool = false) -> RouteTrafficSegment {
            RouteTrafficSegment(id: String(start), routeID: id, startDistance: start, endDistance: end,
                coordinates: route.coordinates, colorHex: 0, isRoadClosure: closed,
                currentSpeedKph: 5, freeFlowSpeedKph: 50, measuredAt: date)
        }
        let measured = [segment(100, 180, id: route.id, date: now), segment(180, 320, id: route.id, date: now),
                        segment(390, 460, id: route.id, date: now, closed: true),
                        segment(600, 700, id: route.id, date: now.addingTimeInterval(-300)),
                        segment(700, 800, id: UUID(), date: now)]
        func notices(_ incidents: [TrafficIncident]) -> [TrafficIncident] {
            RouteTrafficMonitor.flowNotices(in: TrafficSnapshot(flow: nil, incidents: incidents,
                routeFlowSegments: measured, updatedAt: now, partialError: nil, incidentDataAvailable: true),
                on: route, at: now)
        }
        #expect(notices([]).map(\.category) == [.jam, .roadClosed])
        #expect(notices([]).compactMap(\.distanceAlongRoute) == [100, 390])
        let reported = TrafficIncident(id: "reported", description: "Korek", coordinate: coordinate,
            delaySeconds: nil, category: .jam, severity: .moderate, distanceAlongRoute: 120, observedAt: now)
        #expect(notices([reported]).map(\.category) == [.roadClosed])
    }

    @Test
    func staleTrafficIsUnavailableEvenWhenVehiclePositionIsFresh() {
        let state = activeState()
        state.traffic = TrafficSnapshot(flow: nil, incidents: [], updatedAt: now.addingTimeInterval(-600),
                                       partialError: nil, incidentDataAvailable: true)
        #expect(VoiceNavigationActions.answer(.traffic, state: state, now: now).contains("Nie mam aktualnych"))
    }

    @Test
    func alightingRequiresConfirmedRide() {
        let state = activeState()
        state.transportMode = .transit
        state.route?.journey = Journey(departure: now.addingTimeInterval(-300), arrival: now.addingTimeInterval(300),
            legs: [JourneyLeg(mode: "BUS", line: "120", from: "Dworzec", to: "Rynek",
                departure: now.addingTimeInterval(-300), arrival: now.addingTimeInterval(300),
                realTime: false, coordinates: [])])
        state.transitProgress = TransitNavigationProgress(legIndex: 0, legFraction: 0.5, routeFraction: 0.5,
            legDistance: 1_000, distanceToLegEnd: 500, distanceFromRoute: 0,
            nextStop: nil, distanceToNextStop: 100, stopsUntilAlighting: 1, isOnVehicle: false)
        let unconfirmed = VoiceNavigationActions.answer(.transitAlighting, state: state, now: now)
        #expect(unconfirmed.contains("Nie mam jeszcze potwierdzenia"))
        #expect(!unconfirmed.contains("Wysiądź"))
        state.transitProgress?.isOnVehicle = true
        #expect(VoiceNavigationActions.answer(.transitAlighting, state: state, now: now)
            .contains("Wysiądź na następnym przystanku: Rynek"))
    }

    private func activeState() -> NavigationState {
        let start = Coordinate(latitude: 52, longitude: 21)
        let end = Coordinate(latitude: 52.01, longitude: 21)
        let maneuver = Maneuver(shapeIndex: 1, instruction: "Skręć w prawo", type: ManeuverKind.right.rawValue)
        let route = NavigationRoute(coordinates: [start, end], distance: 1_112,
                                    expectedTravelTime: 600, maneuvers: [maneuver])
        let state = NavigationState()
        state.status = .navigating
        state.route = route
        state.location = NavigationLocation(coordinate: start, speed: 10, course: 0, accuracy: 5, timestamp: now)
        state.gpsQuality = .good
        state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: now,
            match: RouteMatch(projection: RouteProjection(coordinate: start, distanceFromRoute: 0,
                alongRoute: 100, segment: 0), confidence: 1))
        state.progress = RouteProgress(traveledDistance: 100, remainingDistance: 1_012,
            remainingTime: 500, distanceToNextManeuver: 200, nextManeuver: maneuver,
            geometryProgress: 0.1, geometryRouteID: route.id)
        state.estimatedArrival = now.addingTimeInterval(500)
        return state
    }
}
#endif
