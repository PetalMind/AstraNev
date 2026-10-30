#if DEBUG && os(iOS)
import Foundation
import SwiftUI

/// An opt-in visual fixture for device screenshots. It never starts a trip,
/// location updates, routing, a report or a history record.
@MainActor
enum IOSDebugDrivingScenario {
    private static var replayTask: Task<Void, Never>?
    private static var startupReplayTask: Task<Void, Never>?
    private static var recenterReplayTask: Task<Void, Never>?
    private static var replayController: MapCameraController?

    private enum Replay: String {
        case turns, roundabout
    }

    private static var replay: Replay? {
        ProcessInfo.processInfo.environment["NAVIASTRA_CAMERA_REPLAY"].flatMap(Replay.init(rawValue:))
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_AUDIT"] == "1" || replay != nil
    }

    static var isPanelReplayEnabled: Bool {
        replay != nil && (ProcessInfo.processInfo.environment["NAVIASTRA_CAMERA_REPLAY_PANELS"] == "1"
            || isStartupReplayEnabled)
    }

    static var isStartupReplayEnabled: Bool {
        replay != nil && ProcessInfo.processInfo.environment["NAVIASTRA_CAMERA_REPLAY_STARTUP"] == "1"
    }

    static func waitForStartupReplay() async {
        await startupReplayTask?.value
    }

    static var panelDetent: NavigationBottomSheetDetent {
        switch ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_PANEL"] {
        case "medium": .medium
        case "expanded": .expanded
        default: .peek
        }
    }

    static func prepare(_ navigationStore: NavigationStore) {
        guard isEnabled else { return }
        replayTask?.cancel()
        replayTask = nil
        startupReplayTask?.cancel()
        startupReplayTask = nil
        recenterReplayTask?.cancel()
        recenterReplayTask = nil
        replayController?.cancelNavigationCameraTasks()
        replayController?.cancelManeuverTransition()
        replayController = nil
        if let replay {
            prepareReplay(replay, store: navigationStore)
            return
        }
        let coordinates = [
            Coordinate(latitude: 51.7593, longitude: 19.4560),
            Coordinate(latitude: 51.7620, longitude: 19.4560),
            Coordinate(latitude: 51.7650, longitude: 19.4560),
            Coordinate(latitude: 51.7650, longitude: 19.4640)
        ]
        let maneuver = Maneuver(shapeIndex: 2, instruction: "Skręć w prawo",
            type: ManeuverKind.right.rawValue, streetNames: ["Pomorska"])
        let distance = zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let route = NavigationRoute(coordinates: coordinates, distance: distance,
            expectedTravelTime: 360, maneuvers: [maneuver])
        let location = NavigationLocation(coordinate: coordinates[0], speed: 0, course: 0,
            accuracy: 5, timestamp: .now, speedAccuracy: 0, courseAccuracy: 5)
        let state = navigationStore.state
        state.transportMode = .car
        state.route = route
        state.routeOptions = [route]
        state.routeOrigin = RoutePoint(Destination(name: "Łódź — początek kontroli",
            coordinate: coordinates[0]), source: .search)
        state.destination = Destination(name: "Łódź — cel kontroli", coordinate: coordinates[3])
        state.location = location
        state.cameraLocation = location
        state.progress = RouteProgress(traveledDistance: 0, remainingDistance: distance,
            remainingTime: 360, distanceToNextManeuver: coordinates[0].distance(to: coordinates[2]),
            nextManeuver: maneuver, geometryProgress: 0, geometryRouteID: route.id)
        state.status = .navigating
        state.cameraState = .followNavigation
        state.cameraIntent = CameraIntent(target: coordinates[0], zoom: 17.5, pitch: 35, bearing: 0,
            padding: .navigation, animationDuration: 0, followCoordinate: coordinates[0])
        state.routeRevealProgress = 1
        state.gpsQuality = .excellent
        state.weakGPS = false
        state.estimatedArrival = Date().addingTimeInterval(360)
        let limit = ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_SPEED_LIMIT"]
            .flatMap(Int.init).flatMap { (1...300).contains($0) ? $0 : nil }
        state.speedLimitKph = limit
        state.speedLimitSource = limit != nil ? .explicitSign : nil
        state.speedLimitMessage = limit != nil ? nil : "Brak limitu w danych drogi."
        state.roadSafetyStatus = .loading
        // didStartLocation remains false: this updates only the render policy.
        navigationStore.refreshEnergyPolicy()
        #if targetEnvironment(simulator)
        prepareSpeedReadoutAudit(navigationStore, coordinate: coordinates[0], routeID: route.id)
        #endif
    }

    #if targetEnvironment(simulator)
    /// Keeps a stationary visual sample fresh without a real GPS or a trip record.
    private static func prepareSpeedReadoutAudit(_ store: NavigationStore,
                                                coordinate: Coordinate, routeID: UUID) {
        guard let speedText = ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_SPEED"],
              let speedKph = Double(speedText), speedKph.isFinite,
              (0...300).contains(speedKph) else { return }
        replayTask = Task { @MainActor in
            while !Task.isCancelled, store.state.route?.id == routeID,
                  store.state.status == .navigating || store.state.status == .rerouting {
                let location = NavigationLocation(coordinate: coordinate, speed: speedKph / 3.6,
                    course: 0, accuracy: 5, timestamp: .now, speedAccuracy: 0, courseAccuracy: 5)
                store.state.location = location
                store.state.cameraLocation = location
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    #endif

    /// A local, synthetic GPS feed through the production camera controller and
    /// renderer. No NavigationSession.begin(), location service or history writer
    /// is involved. The map still loads its ordinary tiles for visual inspection.
    private static func prepareReplay(_ replay: Replay, store: NavigationStore) {
        let route = replayRoute(replay)
        let geometry = RouteProgressGeometry(route)
        let state = store.state
        state.transportMode = .car
        state.route = route
        state.routeOptions = [route]
        state.routeOrigin = RoutePoint(Destination(name: "Kontrola kamery — początek",
            coordinate: route.coordinates[0]), source: .search)
        state.destination = Destination(name: "Kontrola kamery — koniec",
            coordinate: route.coordinates[route.coordinates.count - 1])
        state.status = isStartupReplayEnabled ? .routePreview : .navigating
        state.cameraState = isStartupReplayEnabled ? .routeOverview : .startingNavigation
        state.cameraCommandID &+= 1
        state.routeRevealProgress = 1
        state.gpsQuality = .excellent
        state.weakGPS = false
        state.speedLimitKph = 50
        state.speedLimitSource = .explicitSign
        state.speedLimitMessage = nil
        state.roadSafetyStatus = .idle

        let controller = MapCameraController(state: state, routeMatchProvider: {
            guard let match = state.routeMatch else { return nil }
            return (match.routeID, match.match.projection, match.locationTimestamp)
        }, routeGeometryProvider: { _ in geometry }, refreshTransitVehicles: { _ in })
        replayController = controller
        let environment = ProcessInfo.processInfo.environment
        let startDistance = min(max(0, finiteNumber(environment["NAVIASTRA_CAMERA_REPLAY_START_METERS"]) ?? 0),
                                max(0, geometry.length - 10))
        let defaultDelay = isStartupReplayEnabled ? 8.0 : 6.0
        let delay = min(60, max(0, finiteNumber(environment["NAVIASTRA_CAMERA_REPLAY_DELAY"]) ?? defaultDelay))
        updateReplay(store: store, controller: controller, route: route, geometry: geometry,
                     distance: startDistance, speed: 0, firstFrame: true)
        if isStartupReplayEnabled {
            controller.showRouteOverview()
            startupReplayTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, state.route?.id == route.id,
                          state.status == .routePreview else { return }
                    // Ta sama ścieżka przygotowania kamery co przy rozpoczęciu
                    // podróży, bez uruchamiania sesji, GPS ani zapisu historii.
                    state.status = .navigating
                    state.cameraState = .startingNavigation
                    state.cameraCommandID &+= 1
                    // The overview waited four seconds. Supply a fresh fix as
                    // real GPS would, so this checks startup rather than stale
                    // location recovery and a different route projection.
                    state.gpsQuality = .excellent
                    state.weakGPS = false
                    updateReplay(store: store, controller: controller, route: route, geometry: geometry,
                        distance: startDistance, speed: 0, firstFrame: true)
                    controller.prepareNavigationCamera(for: route) { routeID, projection, timestamp in
                        guard state.route?.id == routeID else { return }
                        state.routeMatch = NavigationRouteMatch(routeID: routeID, locationTimestamp: timestamp,
                            match: RouteMatch(projection: projection, confidence: 1))
                        controller.updateCameraIntent(using: projection)
                    }
                    store.refreshEnergyPolicy()
                } catch {
                    // Kolejny scenariusz anuluje oczekujący start.
                }
            }
        }
        if environment["NAVIASTRA_CAMERA_REPLAY_RECENTER"] == "1" {
            scheduleRecenterReplay(controller: controller, state: state, routeID: route.id)
        }

        replayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            var lastTime = startedAt
            var distance = startDistance
            while !Task.isCancelled, state.route?.id == route.id,
                  state.status == .navigating || state.status == .rerouting {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - startedAt
                let speed = replaySpeed(replay, geometry: geometry, distance: distance, elapsed: elapsed)
                distance = min(geometry.length, distance + speed * min(1.5, max(0, now - lastTime)))
                lastTime = now
                updateReplay(store: store, controller: controller, route: route, geometry: geometry,
                             distance: distance, speed: distance >= geometry.length ? 0 : speed)
                // Retain the last frame for screenshots and panel gestures.
                if distance >= geometry.length { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func scheduleRecenterReplay(controller: MapCameraController,
                                                state: NavigationState, routeID: UUID) {
        recenterReplayTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(40))
                guard !Task.isCancelled, state.route?.id == routeID,
                      state.status == .navigating || state.status == .rerouting else { return }
                // Prawdziwe API kamery zatrzymuje śledzenie. Pozycja nadal płynie,
                // dzięki czemu powrót sprawdza natywne centrowanie w trakcie jazdy.
                controller.setFreeLook()
                try await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, state.route?.id == routeID,
                      state.status == .navigating || state.status == .rerouting else { return }
                controller.returnToFollow()
            } catch {
                // Nowy scenariusz lub zakończenie zadania przerywa kontrolę.
            }
        }
    }

    private static func updateReplay(store: NavigationStore, controller: MapCameraController,
                                     route: NavigationRoute, geometry: RouteProgressGeometry,
                                     distance: Double, speed: Double, firstFrame: Bool = false) {
        guard let coordinate = geometry.coordinate(at: distance) else { return }
        let timestamp = Date()
        let location = NavigationLocation(coordinate: coordinate, speed: speed,
            course: geometry.bearing(at: distance - 5, lookAhead: 12) ?? 0,
            accuracy: 3, timestamp: timestamp, speedAccuracy: 0, courseAccuracy: 2)
        let projection = RouteProjection(coordinate: coordinate, distanceFromRoute: 0,
            alongRoute: distance,
            segment: min(route.coordinates.count - 2, max(0, geometry.firstVertex(after: distance) - 1)))
        let nextManeuver = route.maneuvers.first {
            geometry.cumulativeDistances[$0.shapeIndex] >= distance
        }
        let remaining = max(0, geometry.length - distance)
        let state = store.state
        state.location = location
        state.cameraLocation = location
        state.routeMatch = NavigationRouteMatch(routeID: route.id, locationTimestamp: timestamp,
            match: RouteMatch(projection: projection, confidence: 1))
        state.progress = RouteProgress(traveledDistance: distance, remainingDistance: remaining,
            remainingTime: remaining / max(6, speed),
            distanceToNextManeuver: nextManeuver.map { geometry.cumulativeDistances[$0.shapeIndex] - distance }
                ?? remaining,
            nextManeuver: nextManeuver, geometryProgress: distance / max(1, geometry.length),
            geometryRouteID: route.id)
        state.estimatedArrival = timestamp.addingTimeInterval(remaining / max(6, speed))
        if firstFrame {
            controller.updateCameraIntent(using: projection)
        } else {
            // The controller preserves freeLook/overview after real UI gestures.
            controller.updateNavigationCameraState()
        }
        store.refreshEnergyPolicy()
    }

    private static func replayRoute(_ replay: Replay) -> NavigationRoute {
        let coordinates: [Coordinate]
        let maneuvers: [Maneuver]
        switch replay {
        case .turns:
            coordinates = [point(), point(north: 180), point(east: 170, north: 180),
                point(east: 170, north: 245), point(east: 340, north: 245),
                point(east: 340, north: 420)]
            maneuvers = [
                Maneuver(shapeIndex: 1, instruction: "Skręć w prawo", type: ManeuverKind.right.rawValue),
                Maneuver(shapeIndex: 2, instruction: "Skręć w lewo", type: ManeuverKind.left.rawValue),
                Maneuver(shapeIndex: 3, instruction: "Skręć w prawo", type: ManeuverKind.right.rawValue),
                Maneuver(shapeIndex: 4, instruction: "Skręć w lewo", type: ManeuverKind.left.rawValue)
            ]
        case .roundabout:
            // Approach northbound, then follow 270° of a 28 m radius roundabout.
            let arc = (0...36).map { index in
                let angle = -.pi / 2 + Double(index) * .pi / 24
                return point(east: 28 * cos(angle), north: 208 + 28 * sin(angle))
            }
            coordinates = [point()] + arc + [point(east: -210, north: 208)]
            let guidance = RoundaboutGuidance(exitAngle: -90, clockwise: false, exitCount: 3)
            maneuvers = [
                Maneuver(shapeIndex: 1, instruction: "Na rondzie wybierz trzeci zjazd",
                    type: ManeuverKind.roundaboutEnter.rawValue, roundabout: guidance),
                Maneuver(shapeIndex: arc.count, instruction: "Zjedź z ronda trzecim zjazdem",
                    type: ManeuverKind.roundaboutExit.rawValue, roundabout: guidance)
            ]
        }
        let length = RouteProgressGeometry(coordinates: coordinates).length
        return NavigationRoute(coordinates: coordinates, distance: length,
            expectedTravelTime: length / 9, maneuvers: maneuvers)
    }

    private static func replaySpeed(_ replay: Replay, geometry: RouteProgressGeometry,
                                     distance: Double, elapsed: TimeInterval) -> Double {
        // A short stop on the straight also exposes zoom pumping at traffic lights.
        if (8..<12).contains(elapsed) { return 0 }
        switch replay {
        case .turns: return 11
        case .roundabout:
            let entry = geometry.cumulativeDistances[1]
            let exit = geometry.cumulativeDistances[geometry.coordinates.count - 2]
            return distance >= entry - 35 && distance <= exit + 20 ? 6 : 10
        }
    }

    private static func point(east: Double = 0, north: Double = 0) -> Coordinate {
        Coordinate(latitude: 51.7593 + north / 111_320,
                   longitude: 19.4560 + east / (111_320 * cos(51.7593 * .pi / 180)))
    }

    private static func finiteNumber(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

extension ContentView {
    @MainActor
    func replayNavigationCameraPanels() async {
        guard IOSDebugDrivingScenario.isPanelReplayEnabled else { return }
        let routeID = navigationStore.state.route?.id
        do {
            if IOSDebugDrivingScenario.isStartupReplayEnabled {
                // Czekamy na faktyczne wywołanie API startu, nie na pojawienie
                // się widoku. Padding zmienia się podczas natywnej animacji.
                await IOSDebugDrivingScenario.waitForStartupReplay()
                try await Task.sleep(for: .seconds(0.1))
                guard !Task.isCancelled, navigationStore.state.route?.id == routeID,
                      navigationStore.state.status == .navigating else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                    navigationPanelDetent = .expanded
                }
                try await Task.sleep(for: .seconds(3.9))
            } else {
                try await Task.sleep(for: .seconds(8))
            }
            let detents: [NavigationBottomSheetDetent] = [
                .peek, .medium, .expanded, .peek, .medium, .expanded, .peek
            ]
            for (index, detent) in detents.enumerated() {
                guard !Task.isCancelled, navigationStore.state.route?.id == routeID,
                      navigationStore.state.status == .navigating || navigationStore.state.status == .rerouting
                else { return }
                // Tak samo jak przycisk podsumowania jazdy: zmiana stanu panelu
                // ze sprężyną, bez udawania gestu i bez ustawiania isDragging.
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                    navigationPanelDetent = detent
                }
                if index < detents.count - 1 { try await Task.sleep(for: .seconds(4)) }
            }
        } catch {
            // Zniknięcie widoku kończy kontrolę bez kolejnych zmian panelu.
        }
    }
}
#endif
