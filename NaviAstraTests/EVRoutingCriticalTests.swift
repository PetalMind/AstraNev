import Foundation
import Testing
@testable import NaviAstra

/// Reachability and charging duration affect whether the driver can complete a trip.
@MainActor
struct EVRoutingCriticalTests {
    @Test func rerouteConsumesTheTripDistanceAndOnlyBatteryCorrectionAddsRange() async throws {
        let previousPreferences = UserDefaults.standard.object(forKey: "routingPreferences")
        defer {
            if let previousPreferences { UserDefaults.standard.set(previousPreferences, forKey: "routingPreferences") }
            else { UserDefaults.standard.removeObject(forKey: "routingPreferences") }
        }
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        var preferences = RoutingPreferences()
        preferences.evPlanningEnabled = true
        preferences.evRangeKilometers = 400
        preferences.evBatteryPercent = 75
        session.state.routingPreferences = preferences
        session.state.transportMode = .car
        session.state.status = .navigating
        session.tripSession = TripSession(destination: Destination(name: "Cel",
            coordinate: Coordinate(latitude: 52, longitude: 21)), waypoints: [],
            originalExpectedTravelTime: 3_600, startedAt: .now, lastLocation: nil,
            tracksDriving: false, transportMode: .car)
        session.resetEVBatteryEstimate()
        session.tripSession?.distanceMeters = 120_000
        session.publishEVBatteryEstimate()
        #expect(session.availableEVRangeMeters(for: preferences) == 180_000)
        #expect(session.state.evEstimatedBatteryPercent == 45)
        session.state.status = .rerouting
        #expect(session.availableEVRangeMeters(for: preferences) == 180_000)
        preferences.avoidTolls = true
        await session.updateRoutingPreferences(preferences)
        #expect(session.availableEVRangeMeters(for: preferences) == 180_000)
        preferences.evPlanningEnabled = false
        await session.updateRoutingPreferences(preferences)
        #expect(session.state.evEstimatedBatteryPercent == nil)
        session.tripSession?.distanceMeters = 140_000
        preferences.evPlanningEnabled = true
        await session.updateRoutingPreferences(preferences)
        #expect(session.availableEVRangeMeters(for: preferences) == 160_000)
        preferences.evBatteryPercent = 80
        await session.updateRoutingPreferences(preferences)
        #expect(session.availableEVRangeMeters(for: preferences) == 320_000)
        session.tripSession?.distanceMeters = 200_000
        #expect(session.availableEVRangeMeters(for: preferences) == 260_000)
        session.tripSession?.distanceMeters = 500_000
        #expect(session.availableEVRangeMeters(for: preferences) == 0)
        // A charging stop in the route never constitutes a measured charge.
        session.tripSession = nil
    }

    @Test func chargingPowerBelongsToTheCompatibleConnectorAndChangesChargingTime() throws {
        let station = OpenStreetMapNearbyPlaceProvider.chargingCapabilities(from: [
            "socket:type2": "2", "socket:type2:output": "22 kW",
            "socket:type2_combo": "2", "socket:type2_combo:output": "150000",
            "access": "yes"
        ])
        #expect(station.maximumPowerKW == 150)
        #expect(station.powerKW(for: ["type2"]) == 22)
        #expect(station.powerKW(for: ["ccs"]) == 150)
        #expect(station.powerKW(for: ["type2_combo"]) == 150)
        #expect(station.powerKW(for: ["chademo"]) == nil)
        let slow = EVStopPlanner.chargingTime(from: 0.2, to: 0.8, batteryKWh: 60,
                                               power: try #require(station.powerKW(for: ["type2"])))
        let fast = EVStopPlanner.chargingTime(from: 0.2, to: 0.8, batteryKWh: 60,
                                               power: try #require(station.powerKW(for: ["ccs"])))
        #expect(slow > fast * 3)
        let ambiguous = OpenStreetMapNearbyPlaceProvider.chargingCapabilities(from: [
            "socket:type2": "1", "socket:type2_combo": "1", "charging_station:output": "150 kW"
        ])
        #expect(ambiguous.powerKW(for: ["type2"]) == nil)
        #expect(ambiguous.powerKW(for: ["type2", "ccs"]) == 150)
        #expect(EVBatteryEstimate(fullRangeMeters: .nan, batteryPercent: 50, tripDistance: 0) == nil)
    }
}
