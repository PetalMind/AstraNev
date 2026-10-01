import Foundation

enum NavigationCameraMode: Equatable {
    case following
    case freeLook
    case overview
}

enum NavigationCameraPhase: Equatable {
    case cruising
    case approachingManeuver
    case junction
}

struct NavigationCameraInput {
    let matchedCoordinate: Coordinate
    let routeDistance: Double
    let speed: Double
    let course: Double?
    let distanceToNextManeuver: Double?
    let maneuverAngle: Double?
    let isRoundabout: Bool
    let isMotorwayExit: Bool
    let viewportPadding: CameraPadding
    let timestamp: TimeInterval
    let cameraState: NavigationCameraState
}

/// Turns route progress and navigation context into a smoothed camera intent.
/// It does not access GPS, MapLibre, MapKit, or perform route matching.
@MainActor
final class NavigationCameraEngine {
    private(set) var mode: NavigationCameraMode = .following
    private(set) var phase: NavigationCameraPhase = .cruising

    private var routeGeometry: RouteProgressGeometry?
    private var routeID: UUID?
    private var smoother = NavigationCameraIntentSmoother()
    private var recenterPending = false

    func setRouteGeometry(_ geometry: RouteProgressGeometry) {
        guard routeID != geometry.routeID else { return }
        routeID = geometry.routeID
        routeGeometry = geometry
        resetSmoothing()
    }

    func clearRoute() {
        routeID = nil
        routeGeometry = nil
        phase = .cruising
        resetSmoothing()
    }

    func resetForNavigation() {
        mode = .following
        phase = .cruising
        recenterPending = false
        resetSmoothing()
    }

    func setMode(_ mode: NavigationCameraMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        resetSmoothing()
        recenterPending = mode == .following
    }

    func update(_ input: NavigationCameraInput) -> CameraIntent? {
        guard mode == .following, let routeGeometry else { return nil }
        let speed = input.speed.isFinite ? max(0, input.speed) : 0
        let speedKPH = speed * 3.6
        let maneuverDistance = input.distanceToNextManeuver.flatMap {
            $0.isFinite ? max(0, $0) : nil
        }
        let complexity = maneuverComplexity(input)
        phase = determinePhase(speed: speed, distance: maneuverDistance, complexity: complexity)

        let baseLookAhead = clamp(65 + speed * 6, minimum: 65, maximum: 320)
        let proximityForLookAhead = proximity(distance: maneuverDistance, range: 350)
        let lookAhead = input.cameraState == .approachingDestination ? 20 :
            baseLookAhead * (1 - 0.5 * proximityForLookAhead * complexity)
        let center = routeGeometry.coordinate(at: input.routeDistance + lookAhead)
            ?? input.matchedCoordinate

        let bearingLookAhead = clamp(30 + speed * 2.5, minimum: 30, maximum: 120)
        let routeBearing = routeGeometry.bearing(at: input.routeDistance, lookAhead: bearingLookAhead)
        let desiredBearing = speed < 0.8 || input.cameraState == .weakGPS
            ? smoother.bearing ?? routeBearing ?? input.course ?? 0
            : routeBearing ?? input.course ?? smoother.bearing ?? 0

        let speedZoom = interpolate(speedKPH, through: [
            (0, 18.0), (20, 17.6), (40, 17.1), (60, 16.6),
            (90, 16.0), (120, 15.55), (150, 15.2)
        ])
        let zoomBoost = proximity(distance: maneuverDistance, range: 300) * complexity * 0.9
        let zoom = input.cameraState == .approachingDestination ? 18 :
            clamp(speedZoom + zoomBoost - (input.cameraState == .weakGPS ? 0.4 : 0),
                  minimum: 14.8, maximum: 18.2)

        let speedPitch = interpolate(speedKPH, through: [
            (0, 35), (20, 40), (40, 46), (60, 50),
            (90, 54), (120, 56), (150, 58)
        ])
        let pitchReduction = proximity(distance: maneuverDistance, range: 250) * complexity * 14
        let pitch = input.cameraState == .approachingDestination ? 20 :
            clamp(speedPitch - pitchReduction, minimum: 28, maximum: 58)

        let timestamp = input.timestamp.isFinite ? input.timestamp : Date().timeIntervalSinceReferenceDate
        let desired = CameraIntent(target: center, zoom: zoom, pitch: pitch,
                                   bearing: desiredBearing, padding: input.viewportPadding,
                                   followCoordinate: input.matchedCoordinate)
        let state = smoother.update(
            desired,
            timestamp: timestamp,
            profile: .driving,
            initialAnimationDuration: initialAnimationDuration(for: input.cameraState))
        recenterPending = false
        return state
    }

    private func resetSmoothing() {
        smoother.reset()
    }

    private func maneuverComplexity(_ input: NavigationCameraInput) -> Double {
        if input.isRoundabout { return 1 }
        if input.isMotorwayExit { return 0.8 }
        guard let angle = input.maneuverAngle, angle.isFinite else { return 0 }
        return clamp(abs(angle) / 120, minimum: 0, maximum: 1)
    }

    private func determinePhase(speed: Double, distance: Double?, complexity: Double) -> NavigationCameraPhase {
        guard let distance else { return .cruising }
        if distance < max(55, speed * 4), complexity > 0.45 { return .junction }
        if distance < max(180, speed * 8) { return .approachingManeuver }
        return .cruising
    }

    private func proximity(distance: Double?, range: Double) -> Double {
        guard let distance else { return 0 }
        return 1 - clamp(distance / range, minimum: 0, maximum: 1)
    }

    private func initialAnimationDuration(for cameraState: NavigationCameraState) -> TimeInterval? {
        if cameraState == .startingNavigation { return 0.65 }
        if recenterPending { return 0.75 }
        return nil
    }

    private func interpolate(_ value: Double, through stops: [(Double, Double)]) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if value <= first.0 { return first.1 }
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.0 {
            let fraction = (value - lower.0) / (upper.0 - lower.0)
            return lower.1 + (upper.1 - lower.1) * fraction
        }
        return last.1
    }

    private func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}
