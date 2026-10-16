import CoreLocation
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct BackgroundNavigationCriticalTests {
    @Test(arguments: [TransportMode.walking, .car])
    func lockedScreenKeepsProgressAndFinishesTripWithoutCameraUpdates(mode: TransportMode) async throws {
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        session.state.transportMode = mode
        session.state.voiceEnabled = false
        session.voice.setEnabled(false)
        let destination = Destination(name: "Cel", coordinate: Coordinate(latitude: 52.001, longitude: 21))
        let coordinates = mode == .car
            ? [Coordinate(latitude: 52.0017, longitude: 21),
               Coordinate(latitude: 52.01, longitude: 21), destination.coordinate]
            : [Coordinate(latitude: 52, longitude: 21), destination.coordinate]
        let route = NavigationRoute(coordinates: coordinates,
                                    distance: mode == .car ? 1_924 : 111,
                                    expectedTravelTime: 90, maneuvers: [])
        session.state.route = route
        session.state.destination = destination
        session.state.status = .navigating
        session.state.cameraState = .followNavigation
        session.setAppIsForeground(false)
        let cameraIntent = session.state.cameraIntent
        let base = Date()
        session.tripSession = TripSession(destination: destination, waypoints: [],
            originalExpectedTravelTime: 90, startedAt: base, lastLocation: nil,
            tracksDriving: false, transportMode: mode)
        var completed: [TripRecord] = []
        session.onTripFinished = { completed.append($0) }
        func fix(_ offset: Double) {
            session.locationManager.onLocation?(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: mode == .car ? 52.0017 : 52.0009,
                                                   longitude: 21), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0,
                timestamp: base.addingTimeInterval(offset)))
        }
        fix(0)
        #expect(session.state.status == .navigating)
        if mode == .car {
            // Stopped 78 m beyond the destination, with the planned detour still ahead.
            #expect((session.state.progress?.remainingDistance ?? 0) > 75)
        } else {
            #expect((session.state.progress?.remainingDistance ?? .infinity) < 50)
        }
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

    @Test(arguments: [false, true])
    func arrivalRejectsPassThroughPoorGPSAndReusedFixes(carArrival: Bool) {
        let base = Date()
        func location(_ seconds: Double, speed: Double = 0, accuracy: Double = 5) -> NavigationLocation {
            NavigationLocation(coordinate: Coordinate(latitude: 52, longitude: 21),
                speed: speed, course: 0, accuracy: accuracy, timestamp: base.addingTimeInterval(seconds))
        }
        var detector = ArrivalDetector()
        let destinationDistance = carArrival ? 85.0 : 20.0
        let remainingDistance: Double? = carArrival ? nil : 25
        let destinationRadius = carArrival ? 100.0 : 50.0
        func observe(_ seconds: Double, speed: Double = 0, accuracy: Double = 5,
                     distance: Double? = nil) -> Bool {
            detector.observe(location(seconds, speed: speed, accuracy: accuracy),
                             destinationDistance: distance ?? destinationDistance,
                             remainingDistance: remainingDistance, destinationRadius: destinationRadius,
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
        let acceptedStaleFix = detector.observe(location(0), destinationDistance: destinationDistance,
                                                remainingDistance: remainingDistance,
                                                destinationRadius: destinationRadius,
                                                now: base.addingTimeInterval(30))
        #expect(!acceptedStaleFix)
        #expect(!observe(20))
        #expect(!observe(31))
        #expect(!observe(33))
        #expect(observe(36))
        detector.reset()
        #expect(!observe(40))
        #expect(!observe(42, distance: destinationRadius + 1))
        #expect(!observe(45))
        #expect(!observe(47))
        #expect(observe(50))
        detector.reset()
        for seconds in [60.0, 62, 65] {
            // Transit and pending stops still require route completion.
            let acceptedIncompleteRoute = detector.observe(
                location(seconds), destinationDistance: destinationDistance,
                remainingDistance: 500, destinationRadius: destinationRadius,
                now: base.addingTimeInterval(seconds))
            #expect(!acceptedIncompleteRoute)
        }
    }

    @Test func backgroundProfilesPreserveNavigationAndStopGPSAfterArrival() {
        let engine = EnergyPolicyEngine()
        for mode in [TransportMode.car, .walking, .bicycle, .transit] {
            let active = engine.update(navigationStatus: .rerouting, transportMode: mode,
                appIsForeground: false, lowPowerMode: true, thermalState: .serious,
                speedMetersPerSecond: 33)
            #expect(active.location.demand == .continuous)
            #expect(active.location.accuracy == .bestForNavigation)
            #expect(active.location.allowsBackgroundUpdates)
            #expect(!active.location.updatesHeading)
            #expect(active.mapFramesPerSecond == 0)
            #expect(!active.enables3DBuildings && !active.enablesMapPrefetch)
            #expect(active.location.activity == (mode == .car
                ? .automotiveNavigation : .otherNavigation))
            let arrived = engine.update(navigationStatus: .arrived, transportMode: mode,
                appIsForeground: true, lowPowerMode: false, thermalState: .nominal,
                speedMetersPerSecond: 0)
            #expect(arrived.location.demand == .stopped)
            #expect(!arrived.location.allowsBackgroundUpdates)
        }
    }
}
