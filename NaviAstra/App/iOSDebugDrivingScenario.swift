#if DEBUG && os(iOS)
import Foundation

/// An opt-in visual fixture for device screenshots. It never starts a trip,
/// location updates, routing, a report or a history record.
@MainActor
enum IOSDebugDrivingScenario {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_AUDIT"] == "1"
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
        let hasLimit = ProcessInfo.processInfo.environment["NAVIASTRA_DRIVING_UI_SPEED_LIMIT"] == "50"
        state.speedLimitKph = hasLimit ? 50 : nil
        state.speedLimitSource = hasLimit ? .explicitSign : nil
        state.speedLimitMessage = hasLimit ? nil : "Brak limitu w danych drogi."
        state.roadSafetyStatus = .loading
        // didStartLocation remains false: this updates only the render policy.
        navigationStore.refreshEnergyPolicy()
    }
}
#endif
