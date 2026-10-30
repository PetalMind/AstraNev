import Foundation
import Testing
@testable import NaviAstra

/// Critical regressions in durable trip recording, measurement gaps and replacement navigation.
@MainActor
struct TripRecordingCriticalTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var destination: Destination {
        Destination(name: "Cel", coordinate: Coordinate(latitude: 52.1, longitude: 21))
    }

    private func fix(_ seconds: Double, meters: Double = 0, speed: Double = 10,
                     accuracy: Double = 5, speedAccuracy: Double = 1) -> NavigationLocation {
        NavigationLocation(coordinate: Coordinate(latitude: 52 + meters / 111_132, longitude: 21),
            speed: speed, course: 0, accuracy: accuracy, timestamp: base.addingTimeInterval(seconds),
            speedAccuracy: speedAccuracy, courseAccuracy: 1)
    }

    private func recording(initial: NavigationLocation? = nil) -> TripSession {
        TripSession(destination: destination, waypoints: [], originalExpectedTravelTime: 60,
            startedAt: base, lastLocation: initial, tracksDriving: false, transportMode: .bicycle)
    }

    private func navigation() -> NavigationSession {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.routeProvider = TripRecordingRouteProvider()
        session.state.transportMode = .bicycle
        session.state.voiceEnabled = false
        session.voice.setEnabled(false)
        session.plannedTripCalculation = true
        return session
    }

    @Test func checkpointsBackgroundSaveAndFinalRecordKeepOneIdentity() throws {
        let session = navigation()
        defer { session.stop() }
        let start = Date().addingTimeInterval(-10)
        session.tripSession = TripSession(destination: destination, waypoints: [],
            originalExpectedTravelTime: 60, startedAt: start, lastLocation: nil,
            tracksDriving: false, transportMode: .bicycle)
        session.state.status = .navigating
        var checkpoints: [TripRecord] = []
        var finished: [TripRecord] = []
        session.onTripCheckpoint = { checkpoints.append($0) }
        session.onTripFinished = { finished.append($0) }

        session.checkpointTrip(force: true)
        session.checkpointTrip() // The 15-second throttle avoids rewriting on every GPS fix.
        #expect(checkpoints.count == 1)
        session.checkpointTrip(force: true)
        session.setAppIsForeground(false)
        #expect(checkpoints.count == 3)
        session.stop()
        session.stop()

        let saved = try #require(finished.first)
        #expect(finished.count == 1)
        #expect(checkpoints.allSatisfy { $0.id == saved.id && $0.startedAt == start })
        #expect(saved.terminationReason == .userStopped)
        #expect(session.tripSession == nil)
    }

    @Test func measuredStopsAndMissingGPSAreSeparateAndDistanceHasNoGap() {
        var trip = recording(initial: fix(0))
        trip.record(fix(5, meters: 50, speed: 0), speedLimitKph: nil)
        trip.record(fix(10, meters: 50, speed: 0), speedLimitKph: nil)
        trip.record(fix(50, meters: 450), speedLimitKph: nil)
        trip.record(fix(55, meters: 500), speedLimitKph: nil)
        let result = trip.record(endedAt: base.addingTimeInterval(55), arrived: false,
                                 terminationReason: .userStopped)

        #expect(result.movingSeconds == 10)
        #expect(result.measuredStoppedSeconds == 5)
        #expect(result.unknownSeconds == 40)
        #expect(abs(result.recordingCoverage - 15.0 / 55) < 0.0001)
        #expect(result.distanceSamples.count == 2)
        #expect(result.distanceSamples[0].endedAt == base.addingTimeInterval(5))
        #expect(result.distanceSamples[1].startedAt == base.addingTimeInterval(50))
        #expect(abs(result.distanceSamples.reduce(0) { $0 + $1.distanceMeters } - result.distanceMeters) < 0.0001)
        #expect(result.distanceMeters > 95 && result.distanceMeters < 105)
        #expect(result.trace.contains { $0.startsSegment && $0.timestamp == base.addingTimeInterval(50) })
    }

    @Test func invalidMeasurementsNeverBecomeMeasuredStops() {
        for (speed, accuracy, speedAccuracy) in [(-1.0, 5.0, 1.0), (0, 60, 1), (0, 5, -1), (0, 5, 8)] {
            var trip = recording(initial: fix(0, speed: 0))
            trip.record(fix(5, speed: speed, accuracy: accuracy, speedAccuracy: speedAccuracy), speedLimitKph: nil)
            trip.record(fix(10, speed: 0), speedLimitKph: nil)
            let result = trip.record(endedAt: base.addingTimeInterval(10), arrived: false,
                                     terminationReason: .userStopped)
            #expect(result.movingSeconds == 0)
            #expect(result.measuredStoppedSeconds == 0)
            #expect(result.unknownSeconds == 10)
            #expect(result.distanceSamples.isEmpty)
        }
    }

    @Test func startClipsTheFirstMeasurementAndDiscardsStaleInitialFix() {
        var clipped = recording(initial: fix(-10, meters: -100))
        clipped.record(fix(5, meters: 50), speedLimitKph: nil)
        let accepted = clipped.record(endedAt: base.addingTimeInterval(5), arrived: false,
                                      terminationReason: .userStopped)
        #expect(accepted.movingSeconds == 5)
        #expect(accepted.distanceMeters > 45 && accepted.distanceMeters < 55)
        #expect(accepted.distanceSamples.first?.startedAt == base)
        #expect(accepted.unknownSeconds == 0)

        var stale = recording(initial: fix(-20, meters: -200))
        stale.record(fix(5, meters: 50), speedLimitKph: nil)
        let discarded = stale.record(endedAt: base.addingTimeInterval(5), arrived: false,
                                     terminationReason: .userStopped)
        #expect(discarded.distanceMeters == 0)
        #expect(discarded.movingSeconds == 0)
        #expect(discarded.unknownSeconds == 5)
        #expect(discarded.trace.first?.timestamp == base.addingTimeInterval(5))
    }

    @Test func finalReliableFixSurvivesSamplingAndRepeatedSnapshots() {
        var trip = recording(initial: fix(0))
        trip.record(fix(1, meters: 10), speedLimitKph: nil)
        #expect(trip.traceRecorder.points.count == 1)
        let checkpoint = trip.record(endedAt: base.addingTimeInterval(1), arrived: false,
                                      terminationReason: nil)
        let finished = trip.record(endedAt: base.addingTimeInterval(1), arrived: true,
                                    terminationReason: .completed)
        #expect(checkpoint.trace.count == 2)
        #expect(finished.trace.count == 2)
        #expect(checkpoint.trace.last?.timestamp == base.addingTimeInterval(1))
        #expect(finished.trace.last?.coordinate == fix(1, meters: 10).coordinate)
        #expect(checkpoint.id == finished.id)
    }

    @Test func replayFinalizesBeforeRoutingAndBeforeTheNextStart() async throws {
        let session = navigation()
        defer { session.stop() }
        let previous = recording()
        session.tripSession = previous
        session.state.status = .navigating
        session.state.destination = destination
        session.state.routeOrigin = RoutePoint(Destination(name: "Start", coordinate: fix(0).coordinate), source: .search)
        let waypoint = Destination(name: "Przystanek", coordinate: Coordinate(latitude: 52.04, longitude: 21))
        session.state.waypoints = [waypoint]
        var finished: [TripRecord] = []
        var events: [String] = []
        session.onTripFinished = { finished.append($0); events.append("finished") }
        session.onTripCheckpoint = { _ in events.append("checkpoint") }
        let provider = TripRecordingRouteProvider()
        provider.onRequest = {
            #expect(finished.count == 1)
            #expect(session.tripSession == nil)
            events.append("routing")
        }
        session.routeProvider = provider

        await session.previewNewTrip(destination, transportMode: .bicycle)
        provider.onRequest = nil
        #expect(events == ["finished", "routing"])
        #expect(finished.first?.id == previous.id)
        #expect(finished.first?.terminationReason == .replaced)
        #expect(session.state.waypoints == [waypoint])
        #expect(session.state.transportMode == .bicycle)
        #expect(session.state.status == .routePreview)
        session.begin()
        let nextID = try #require(session.tripSession?.id)
        #expect(nextID != previous.id)
        #expect(events == ["finished", "routing", "checkpoint"])
        session.stop()
        #expect(finished.count == 2)
        #expect(finished.last?.id == nextID)
    }

    @Test func directStartCannotOverwriteAnUnfinishedRecording() throws {
        let session = navigation()
        defer { session.stop() }
        let previous = recording()
        session.tripSession = previous
        session.state.status = .routePreview
        session.state.destination = destination
        session.state.route = NavigationRoute(coordinates: [fix(0).coordinate, destination.coordinate],
            distance: 1_000, expectedTravelTime: 60, maneuvers: [])
        var completedIDs: [UUID] = []
        var checkpointIDs: [UUID] = []
        session.onTripFinished = { completedIDs.append($0.id) }
        session.onTripCheckpoint = {
            #expect(completedIDs == [previous.id])
            checkpointIDs.append($0.id)
        }
        session.begin()
        let nextID = try #require(session.tripSession?.id)
        #expect(nextID != previous.id)
        #expect(completedIDs == [previous.id])
        #expect(checkpointIDs == [nextID])
        session.stop()
    }
}

@MainActor
private final class TripRecordingRouteProvider: AdvancedRouteProvider {
    var onRequest: (() -> Void)?

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        onRequest?()
        return [NavigationRoute(coordinates: [from, to], distance: 1_000,
                                expectedTravelTime: 60, maneuvers: [])]
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, mode: mode)
    }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination],
                                mode: TransportMode, preferences: RoutingPreferences) async throws -> [Int] {
        Array(waypoints.indices)
    }
}
