import CoreLocation
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct BackgroundNavigationCriticalTests {
    @Test func lockedScreenKeepsProgressAndFinishesTripWithoutCameraUpdates() async throws {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.state.transportMode = .walking
        session.state.voiceEnabled = false
        session.voice.setEnabled(false)
        let destination = Destination(name: "Cel", coordinate: Coordinate(latitude: 52.001, longitude: 21))
        let route = NavigationRoute(coordinates: [Coordinate(latitude: 52, longitude: 21), destination.coordinate],
                                    distance: 111, expectedTravelTime: 90, maneuvers: [])
        session.state.route = route
        session.state.destination = destination
        session.state.status = .navigating
        session.state.cameraState = .followNavigation
        session.setAppIsForeground(false)
        let cameraIntent = session.state.cameraIntent
        let base = Date()
        session.tripSession = TripSession(destination: destination, waypoints: [],
            originalExpectedTravelTime: 90, startedAt: base, lastLocation: nil,
            tracksDriving: false, transportMode: .walking)
        var completed: [TripRecord] = []
        session.onTripFinished = { completed.append($0) }
        func fix(_ offset: Double) {
            session.locationManager.onLocation?(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 52.0009, longitude: 21), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0,
                timestamp: base.addingTimeInterval(offset)))
        }
        fix(0)
        #expect(session.state.status == .navigating)
        #expect((session.state.progress?.remainingDistance ?? .infinity) < 50)
        #expect(session.state.cameraIntent == cameraIntent)
        // Traffic/timer refreshes reuse the GPS sample and cannot cause arrival.
        for _ in 0..<10 { session.updateProgress() }
        #expect(session.state.status == .navigating)
        try await Task.sleep(for: .seconds(2))
        fix(2)
        #expect(session.state.status == .navigating)
        try await Task.sleep(for: .seconds(3))
        fix(5)
        #expect(session.state.status == .arrived)
        #expect(session.energyPolicyEngine.currentPolicy.location.demand == .stopped)
        #expect(session.energyPolicyEngine.currentPolicy.mapFramesPerSecond == 0)
        #expect(completed.count == 1)
        #expect(completed.first?.arrived == true)
        #expect(session.state.arrivalLocation != nil)
        session.updateProgress()
        session.stop()
        #expect(completed.count == 1)
    }

    @Test func arrivalRejectsPassThroughPoorGPSAndReusedFixes() {
        let base = Date()
        func location(_ seconds: Double, speed: Double = 0, accuracy: Double = 5) -> NavigationLocation {
            NavigationLocation(coordinate: Coordinate(latitude: 52, longitude: 21),
                speed: speed, course: 0, accuracy: accuracy, timestamp: base.addingTimeInterval(seconds))
        }
        var detector = ArrivalDetector()
        func observe(_ seconds: Double, speed: Double = 0, accuracy: Double = 5) -> Bool {
            detector.observe(location(seconds, speed: speed, accuracy: accuracy),
                             destinationDistance: 20, remainingDistance: 25,
                             now: base.addingTimeInterval(seconds))
        }
        #expect(!observe(0))
        #expect(!observe(2))
        #expect(!observe(5, speed: 10))
        #expect(!observe(6))
        #expect(!observe(8, accuracy: 60))
        #expect(!observe(9))
        #expect(!observe(9))
        #expect(!observe(12))
        #expect(observe(14))
        detector.reset()
        let acceptedStaleFix = detector.observe(location(0), destinationDistance: 20, remainingDistance: 25,
                                                now: base.addingTimeInterval(30))
        #expect(!acceptedStaleFix)
        #expect(!observe(20))
        #expect(!observe(31))
        #expect(!observe(33))
        #expect(observe(36))
    }

    @Test func backgroundProfilesPreserveNavigationAndStopGPSAfterArrival() {
        let engine = EnergyPolicyEngine()
        for mode in [TransportMode.car, .walking, .bicycle, .transit, .parkRide] {
            let active = engine.update(navigationStatus: .rerouting, transportMode: mode,
                appIsForeground: false, lowPowerMode: true, thermalState: .serious,
                speedMetersPerSecond: 33)
            #expect(active.location.demand == .continuous)
            #expect(active.location.accuracy == .bestForNavigation)
            #expect(active.location.allowsBackgroundUpdates)
            #expect(!active.location.updatesHeading)
            #expect(active.mapFramesPerSecond == 0)
            #expect(!active.enables3DBuildings && !active.enablesMapPrefetch)
            #expect(active.location.activity == (mode == .car || mode == .parkRide
                ? .automotiveNavigation : .otherNavigation))
            let arrived = engine.update(navigationStatus: .arrived, transportMode: mode,
                appIsForeground: true, lowPowerMode: false, thermalState: .nominal,
                speedMetersPerSecond: 0)
            #expect(arrived.location.demand == .stopped)
            #expect(!arrived.location.allowsBackgroundUpdates)
        }
    }
}
