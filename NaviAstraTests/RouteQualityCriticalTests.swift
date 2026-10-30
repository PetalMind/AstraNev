import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct RouteQualityCriticalTests {
    @Test func observedPredictionsSurvivePersistenceAndReplayOnlyCompletedMeasuredTrips() throws {
        let routeID = UUID()
        var recorder = RouteQualityRecorder()
        recorder.observe(elapsed: 0, remaining: 600, routeID: routeID, trafficCoverage: 0.7)
        recorder.observe(elapsed: 10, remaining: 590, routeID: routeID, trafficCoverage: 0.7)
        recorder.observe(elapsed: 60, remaining: 570, routeID: routeID, trafficCoverage: 0.8)
        recorder.observe(elapsed: 70, remaining: 560, routeID: UUID(), trafficCoverage: 0.8)
        recorder.observe(elapsed: 80, remaining: .infinity, routeID: UUID(), trafficCoverage: nil)
        let measurement = try #require(recorder.measurement)
        #expect(measurement.observations.count == 3)
        #expect(measurement.arrivalErrors(actualDuration: 660) == [60, 30, 30])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var trip = TripRecord(destination: Destination(name: "Cel", coordinate: Coordinate(latitude: 52, longitude: 21)),
            startedAt: start, endedAt: start.addingTimeInterval(660), distanceMeters: 8_000,
            movingSeconds: 600, rerouteCount: 1, arrived: true, transportMode: .car,
            measuredStoppedSeconds: 60)
        trip.routingQuality = measurement
        let restored = try JSONDecoder().decode(TripRecord.self, from: JSONEncoder().encode(trip))
        let replay = RouteQualityReplay.replay([restored])
        #expect(replay.journeys.count == 1)
        #expect(replay.meanInitialAbsoluteError == 60)
        #expect(replay.journeys.first?.meanAbsoluteErrorSeconds == 40)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as? [String: Any])
        payload["routingQuality"] = ["observations": "uszkodzony pomiar"]
        let damaged = try JSONDecoder().decode(TripRecord.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(damaged.id == trip.id)
        #expect(damaged.routingQuality == nil)
        trip.arrived = false
        #expect(RouteQualityReplay.replay([trip]).journeys.isEmpty)
        trip.arrived = true
        trip.movingSeconds = 100
        #expect(RouteQualityReplay.replay([trip]).journeys.isEmpty)
        recorder.invalidateForPlanChange()
        recorder.observe(elapsed: 120, remaining: 900, routeID: UUID(), trafficCoverage: nil)
        #expect(recorder.measurement == nil)
    }
}
