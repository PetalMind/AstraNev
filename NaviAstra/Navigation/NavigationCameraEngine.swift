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
    case recovering
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
    var maneuverIndex: Int? = nil
    /// Distance from the current position to the maneuver after the next one.
    var followingManeuverDistance: Double? = nil
    var connectsRoundaboutEntryAndExit = false
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
    private var attention = 0.0
    private var filteredSpeed: Double?
    private var previousTimestamp: TimeInterval?
    private var previousManeuverIndex: Int?
    private var recoveryUntil: TimeInterval = 0

    func setRouteGeometry(_ geometry: RouteProgressGeometry) {
        guard routeGeometry == nil || routeID != geometry.routeID else { return }
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
        let timestamp = input.timestamp.isFinite ? input.timestamp : ProcessInfo.processInfo.systemUptime
        let elapsed = previousTimestamp.map { min(1, max(0, timestamp - $0)) } ?? 0
        let measuredSpeed = input.speed.isFinite ? max(0, input.speed) : 0
        let oldSpeed = filteredSpeed ?? measuredSpeed
        // A stop at traffic lights must not collapse the driver's view of the junction.
        let speedResponse = measuredSpeed < oldSpeed ? 3.0 : 1.4
        let speed = input.cameraState == .weakGPS ? oldSpeed :
            oldSpeed + (measuredSpeed - oldSpeed) * (1 - exp(-elapsed / speedResponse))
        filteredSpeed = speed
        let speedKPH = speed * 3.6
        let maneuverDistance = input.distanceToNextManeuver.flatMap {
            $0.isFinite ? max(0, $0) : nil
        }
        let complexity = maneuverComplexity(input)
        let approachRange = clamp(max(speed, 5) * (input.isMotorwayExit ? 20 : 14),
                                  minimum: 100, maximum: input.isMotorwayExit ? 700 : 420)
        let maneuverAttention = smoothstep(proximity(distance: maneuverDistance, range: approachRange)) * complexity
        let nearBearing = routeGeometry.bearing(at: input.routeDistance - 5,
            lookAhead: clamp(12 + speed * 0.45, minimum: 12, maximum: 26))
        let farBearing = routeGeometry.bearing(at: input.routeDistance,
            lookAhead: clamp(40 + speed * 3, minimum: 40, maximum: 140))
        let bend = abs(shortestAngle(from: nearBearing ?? farBearing ?? 0,
                                     to: farBearing ?? nearBearing ?? 0))
        let bendAttention = smoothstep(clamp(bend / 85, minimum: 0, maximum: 1)) * 0.7
        let requestedAttention = max(maneuverAttention, bendAttention)
        if let previousManeuverIndex, previousManeuverIndex != input.maneuverIndex, attention > 0.25 {
            recoveryUntil = timestamp + 1.8
        }
        let heldAttention = timestamp < recoveryUntil ? max(attention, requestedAttention) : requestedAttention
        if previousTimestamp == nil {
            attention = requestedAttention
        } else {
            let response = heldAttention > attention ? 0.65 : 3.6
            attention += (heldAttention - attention) * (1 - exp(-elapsed / response))
        }
        previousTimestamp = timestamp
        previousManeuverIndex = input.maneuverIndex
        phase = determinePhase(speed: speed, distance: maneuverDistance, complexity: complexity)
        if phase == .cruising && attention > requestedAttention + 0.12 { phase = .recovering }

        // Keep the normal driving view close behind the vehicle. Junctions
        // retain a wider context budget so nearby exits are still framed.
        let baseLookAhead = clamp(50 + speed * 6, minimum: 60, maximum: 270)
        let maneuverLookAhead = clamp(70 + speed * 9, minimum: 80, maximum: 380)
        var lookAhead = baseLookAhead * (1 - 0.55 * attention)
        if let maneuverDistance, maneuverDistance < approachRange * 1.35, complexity > 0.25 {
            // Include the exit road, and retain a close second decision in the same frame.
            var contextEnd = maneuverDistance + clamp(25 + speed * 2, minimum: 35, maximum: 80)
            if let following = input.followingManeuverDistance, following.isFinite,
               following > maneuverDistance,
               input.connectsRoundaboutEntryAndExit || following - maneuverDistance < max(65, speed * 6) {
                // Prepare the curve before entering it, even when the exit is
                // farther than the ordinary close-maneuver threshold.
                contextEnd = following + 35
            }
            // Introduce the exit context before the approach threshold. A hard
            // switch here used to add half a roundabout in a single GPS fix,
            // faster than the renderer could safely zoom out.
            let contextBlend = smoothstep(clamp(
                (approachRange * 1.35 - maneuverDistance) / (approachRange * 0.35),
                minimum: 0, maximum: 1))
            lookAhead += max(0, min(maneuverLookAhead, contextEnd) - lookAhead) * contextBlend
        }
        if input.cameraState == .approachingDestination { lookAhead = 45 }
        if input.cameraState == .weakGPS { lookAhead = min(lookAhead, 120) }
        let center = routeGeometry.coordinate(at: input.routeDistance + lookAhead)
            ?? input.matchedCoordinate

        let course = input.course.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let roadBearing = nearBearing ?? course ?? smoother.bearing ?? 0
        let anticipationLimit = 8 + 10 * (1 - attention)
        let anticipation = clamp(shortestAngle(from: roadBearing, to: farBearing ?? roadBearing) * 0.3,
                                 minimum: -anticipationLimit, maximum: anticipationLimit)
        let desiredBearing = measuredSpeed < 0.8 || input.cameraState == .weakGPS
            ? smoother.bearing ?? roadBearing
            : roadBearing + anticipation

        let speedZoom = interpolate(speedKPH, through: [
            (0, 18.0), (20, 17.8), (40, 17.55), (60, 17.25),
            (90, 16.8), (120, 16.4), (150, 16.1)
        ])
        let zoom = input.cameraState == .approachingDestination ? 17.7 :
            clamp(speedZoom + attention * 0.65 - (input.cameraState == .weakGPS ? 0.25 : 0),
                  minimum: 14.8, maximum: 18.2)

        let speedPitch = interpolate(speedKPH, through: [
            (0, 52), (20, 54), (40, 56), (60, 58),
            (90, 60), (120, 60), (150, 60)
        ])
        let pitch = input.cameraState == .approachingDestination ? 22 :
            clamp(speedPitch - attention * 14, minimum: 38, maximum: 60)

        var desired = CameraIntent(target: center, zoom: zoom, pitch: pitch,
            bearing: (desiredBearing.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360), padding: input.viewportPadding,
            followCoordinate: input.matchedCoordinate,
            anchorFraction: input.cameraState == .approachingDestination ? 0.62 : 0.82 - attention * 0.10)
        desired.framingCoordinates = (0...12).compactMap {
            routeGeometry.coordinate(at: input.routeDistance + lookAhead * Double($0) / 12)
        }
        if let maneuverDistance, maneuverDistance <= lookAhead,
           let turn = routeGeometry.coordinate(at: input.routeDistance + maneuverDistance) {
            desired.framingCoordinates.append(turn)
        }
        var profile = NavigationCameraSmoothingProfile.driving
        if let previousZoom = smoother.zoom, zoom < previousZoom { profile.zoomResponseTime = 2.8 }
        let state = smoother.update(
            desired,
            timestamp: timestamp,
            profile: profile,
            initialAnimationDuration: initialAnimationDuration(for: input.cameraState))
        recenterPending = false
        return state
    }

    private func resetSmoothing() {
        smoother.reset()
        attention = 0
        filteredSpeed = nil
        previousTimestamp = nil
        previousManeuverIndex = nil
        recoveryUntil = 0
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

    private func smoothstep(_ value: Double) -> Double { value * value * (3 - 2 * value) }

    private func shortestAngle(from start: Double, to end: Double) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func initialAnimationDuration(for cameraState: NavigationCameraState) -> TimeInterval? {
        if cameraState == .startingNavigation { return NavigationCameraTiming.start }
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
