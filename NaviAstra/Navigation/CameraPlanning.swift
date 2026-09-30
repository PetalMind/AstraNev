import Foundation

/// The navigation engine owns the state and intent. Map adapters only animate it.
enum NavigationCameraState: Equatable {
    case browse, destinationPreview, routeOverview, startingNavigation
    case followNavigation, approachingManeuver, maneuverNow, leavingManeuver, freeLook, rerouting
    case weakGPS, approachingDestination, arrived

    var usesNavigationPerspective: Bool {
        switch self {
        case .startingNavigation, .followNavigation, .approachingManeuver, .maneuverNow,
             .leavingManeuver, .rerouting, .weakGPS, .approachingDestination:
            return true
        case .browse, .destinationPreview, .routeOverview, .freeLook, .arrived:
            return false
        }
    }
}

struct CameraPadding: Equatable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static let destination = Self(top: 110, left: 55, bottom: 250, right: 55)
    static let route = Self(top: 110, left: 50, bottom: 300, right: 50)
    static let navigation = Self(top: 85, left: 40, bottom: 220, right: 40)
}

struct CameraIntent: Equatable {
    var target: Coordinate
    var zoom: Double
    var pitch: Double
    var bearing: Double
    var padding: CameraPadding
    var bounds: [Coordinate] = []
    var animationDuration: TimeInterval? = nil
}

struct NavigationCameraSmoothingProfile {
    var targetResponseTime: TimeInterval
    var zoomResponseTime: TimeInterval
    var pitchResponseTime: TimeInterval
    var bearingResponseTime: TimeInterval

    static let driving = Self(targetResponseTime: 0.30, zoomResponseTime: 0.50,
                              pitchResponseTime: 0.55, bearingResponseTime: 0.25)
    static let walking = Self(targetResponseTime: 0.42, zoomResponseTime: 1.10,
                              pitchResponseTime: 0.85, bearingResponseTime: 1.25)
    static let transit = Self(targetResponseTime: 0.50, zoomResponseTime: 1.15,
                              pitchResponseTime: 0.95, bearingResponseTime: 1.55)
}

/// Shared smoothing for policy-produced intents, independent of the map renderer.
struct NavigationCameraIntentSmoother {
    private var previousIntent: CameraIntent?
    private var previousTimestamp: TimeInterval?

    var bearing: Double? { previousIntent?.bearing }

    mutating func reset() {
        previousIntent = nil
        previousTimestamp = nil
    }

    mutating func update(_ desired: CameraIntent, timestamp: TimeInterval,
                         profile: NavigationCameraSmoothingProfile,
                         initialAnimationDuration: TimeInterval? = nil,
                         animationDuration: TimeInterval? = nil) -> CameraIntent {
        let timestamp = timestamp.isFinite ? timestamp : Date().timeIntervalSinceReferenceDate
        if !desired.bounds.isEmpty {
            previousIntent = desired
            previousTimestamp = timestamp
            return desired
        }
        guard let previousIntent, let previousTimestamp else {
            var initial = desired
            initial.animationDuration = desired.animationDuration ?? initialAnimationDuration
            self.previousIntent = initial
            self.previousTimestamp = timestamp
            return initial
        }

        let deltaTime = max(0.016, timestamp - previousTimestamp)
        let smoothed = CameraIntent(
            target: interpolate(previousIntent.target, desired.target,
                                alpha: smoothingAlpha(deltaTime, responseTime: profile.targetResponseTime)),
            zoom: interpolate(previousIntent.zoom, desired.zoom,
                              alpha: smoothingAlpha(deltaTime, responseTime: profile.zoomResponseTime)),
            pitch: interpolate(previousIntent.pitch, desired.pitch,
                               alpha: smoothingAlpha(deltaTime, responseTime: profile.pitchResponseTime)),
            bearing: smoothAngle(current: previousIntent.bearing, target: desired.bearing,
                                 alpha: smoothingAlpha(deltaTime, responseTime: profile.bearingResponseTime)),
            padding: desired.padding,
            bounds: desired.bounds,
            animationDuration: desired.animationDuration ?? animationDuration ??
                clamp(deltaTime * 1.1, minimum: 0.20, maximum: 0.85))
        self.previousIntent = smoothed
        self.previousTimestamp = timestamp
        return smoothed
    }

    private func smoothingAlpha(_ deltaTime: TimeInterval, responseTime: TimeInterval) -> Double {
        1 - exp(-deltaTime / responseTime)
    }

    private func interpolate(_ start: Double, _ end: Double, alpha: Double) -> Double {
        start + (end - start) * alpha
    }

    private func interpolate(_ start: Coordinate, _ end: Coordinate, alpha: Double) -> Coordinate {
        Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * alpha,
                   longitude: start.longitude + (end.longitude - start.longitude) * alpha)
    }

    private func smoothAngle(current: Double, target: Double, alpha: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return (current + delta * alpha + 360).truncatingRemainder(dividingBy: 360)
    }

    private func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

/// Stabilizes the camera's route-derived bearing across noisy GPS fixes while
/// still allowing it to turn with the road geometry.
struct NavigationCameraHeadingFilter {
    private(set) var bearing: Double?
    private var lastLocationTimestamp: Date?
    private var lastUpdatedAt: Date?
    private var lastTargetWasRoute = false

    mutating func reset() {
        bearing = nil
        lastLocationTimestamp = nil
        lastUpdatedAt = nil
        lastTargetWasRoute = false
    }

    mutating func update(routeHeading: Double?, location: NavigationLocation?,
                         now: Date = .now) -> Double? {
        guard let location else { return bearing }
        let speed = CameraPlanner.usableSpeed(from: location)
        let course = CameraPlanner.usableCourse(from: location, speed: speed)
        guard let target = routeHeading ?? course else { return bearing }

        let isSameFix = lastLocationTimestamp == location.timestamp
        guard !isSameFix || (routeHeading != nil && !lastTargetWasRoute) else { return bearing }

        let elapsed: TimeInterval
        if isSameFix {
            elapsed = min(0.35, max(0.12, now.timeIntervalSince(lastUpdatedAt ?? now)))
        } else if let lastLocationTimestamp {
            elapsed = min(2, max(0.1, location.timestamp.timeIntervalSince(lastLocationTimestamp)))
        } else {
            elapsed = 0.35
        }

        if let current = bearing {
            let delta = Self.shortestAngle(from: current, to: target)
            let smoothedDelta = delta * (1 - exp(-elapsed / 1.25))
            let maximumDelta = 55 * elapsed
            bearing = Self.normalized(current + min(maximumDelta, max(-maximumDelta, smoothedDelta)))
        } else {
            bearing = Self.normalized(target)
        }
        lastLocationTimestamp = location.timestamp
        lastUpdatedAt = now
        lastTargetWasRoute = routeHeading != nil
        return bearing
    }

    private static func shortestAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalized(_ value: Double) -> Double {
        (value + 360).truncatingRemainder(dividingBy: 360)
    }
}

enum WalkingCameraState: Equatable {
    case overview, cruising, approachingTurn, maneuver, stopped
}

struct WalkingCameraSnapshot: Equatable {
    var bearing: Double?
    var stoppedDuration: TimeInterval
}

struct WalkingCameraProfile: Equatable {
    var state: WalkingCameraState
    var zoom: Double
    var pitch: Double
    var lookAhead: Double
    var animationDuration: TimeInterval
}

enum TransitCameraPhase: Equatable {
    case locating
    case walkingToStop
    case waitingAtStop
    case riding
    case approachingTransfer
    case transferOverview
    case transferWalking
    case approachingDestination
    case walkingToDestination
}

struct TransitCameraPlan {
    let phase: TransitCameraPhase
    let intent: CameraIntent

    var followsWalkingRoute: Bool {
        switch phase {
        case .walkingToStop, .transferWalking, .walkingToDestination: true
        default: false
        }
    }
}

/// Selects a camera profile from the currently active leg of a transit journey.
/// It uses journey geometry and realtime vehicle positions only when available.
enum TransitCameraPolicy {
    static func plan(route: NavigationRoute, progress: TransitNavigationProgress,
                     location: NavigationLocation?, vehicles: [TransitVehicle],
                     nearbyStops: [TransitStop], previousBearing: Double,
                     showTransferOverview: Bool, now: Date = .now) -> TransitCameraPlan? {
        guard let journey = route.journey, journey.legs.indices.contains(progress.legIndex) else { return nil }
        let leg = journey.legs[progress.legIndex]
        let isWalkingLeg = leg.mode.uppercased() == "WALK"
        let previousRide = journey.legs[..<progress.legIndex].last { $0.mode.uppercased() != "WALK" }
        let nextRide = journey.legs.dropFirst(progress.legIndex + 1).first { $0.mode.uppercased() != "WALK" }
        let current = progress.routeProjection?.coordinate ?? location?.coordinate ??
            leg.coordinates.first ?? route.coordinates.first
        guard let current else { return nil }

        if isWalkingLeg {
            let isTransfer = previousRide != nil && nextRide != nil
            if isTransfer, showTransferOverview {
                let previousStop = previousRide?.transitStops.last?.coordinate
                let nextStop = nextRide?.transitStops.first?.coordinate
                var bounds = leg.coordinates
                if let previousStop { bounds.append(previousStop) }
                if let nextStop { bounds.append(nextStop) }
                if bounds.count >= 2 {
                    return TransitCameraPlan(
                        phase: .transferOverview,
                        intent: CameraIntent(target: blend(previousStop ?? current, nextStop ?? current, 0.5),
                                             zoom: 18, pitch: 0, bearing: 0, padding: .navigation,
                                             bounds: bounds, animationDuration: 0.8))
                }
            }

            let phase: TransitCameraPhase = isTransfer ? .transferWalking :
                (previousRide == nil && nextRide != nil ? .walkingToStop : .walkingToDestination)
            let speed = usableSpeed(location)
            var lookAhead = min(50, max(20, 20 + speed * 5))
            let geometry = RouteProgressGeometry(coordinates: leg.coordinates)
            let currentBearing = geometry.bearing(at: progress.legDistance, lookAhead: 10)
            let afterBearing = geometry.bearing(at: progress.legDistance + 14, lookAhead: 24)
            let nearJunction = currentBearing.flatMap { first in
                afterBearing.map { abs(shortestAngle(from: first, to: $0)) >= 38 }
            } ?? false
            var zoom = 18.0
            var pitch = 30.0
            if nearJunction || progress.distanceToLegEnd <= 30 {
                zoom = 18.5
                pitch = 18
                lookAhead = min(lookAhead, 20)
            }
            let routeBearing = geometry.bearing(at: progress.legDistance, lookAhead: max(15, lookAhead))
            let course = usableCourse(location, speed: speed)
            let bearing = routeBearing ?? course ?? previousBearing
            var target = geometry.coordinate(at: progress.legDistance + lookAhead) ?? current
            let endpoint = phase == .walkingToStop
                ? nextRide?.transitStops.first?.coordinate ?? nextRide?.coordinates.first
                : leg.coordinates.last
            if let endpoint, let location {
                let distance = location.coordinate.distance(to: endpoint)
                let influence = 1 - clamp(distance / 250, minimum: 0, maximum: 1)
                target = blend(target, endpoint, influence * 0.8)
            }
            if let hub = nearbyStops
                .filter(\.isLargeTransitNode)
                .min(by: { $0.coordinate.distance(to: current) < $1.coordinate.distance(to: current) }),
               hub.coordinate.distance(to: current) <= 150 {
                zoom = 18.2
                pitch = 0
            }

            return TransitCameraPlan(
                phase: phase,
                intent: CameraIntent(target: target, zoom: zoom, pitch: pitch, bearing: bearing,
                                     padding: .navigation))
        }

        let boardingStop = leg.transitStops.first?.coordinate ?? leg.coordinates.first
        let isNearBoardingStop = boardingStop.map { current.distance(to: $0) <= 85 } ??
            (progress.legDistance <= 80)
        if !progress.isOnVehicle, isNearBoardingStop, progress.legDistance <= 100 {
            let stop = boardingStop ?? current
            let hub = nearbyStops
                .filter(\.isLargeTransitNode)
                .min(by: { $0.coordinate.distance(to: stop) < $1.coordinate.distance(to: stop) })
            let isHub = hub.map { $0.coordinate.distance(to: stop) <= 180 } ?? false
            let target = blend(current, stop, 0.45)
            return TransitCameraPlan(
                phase: .waitingAtStop,
                intent: CameraIntent(target: target, zoom: isHub ? 18 : 17,
                                     pitch: 0, bearing: 0, padding: .navigation))
        }

        let endStop = leg.transitStops.last
        let distanceToAlightingStop = progress.distanceToLegEnd.isFinite
            ? max(0, progress.distanceToLegEnd)
            : endStop.map { current.distance(to: $0.coordinate) } ?? .infinity
        let isApproachingStop = (progress.stopsUntilAlighting.map { $0 <= 2 } ?? false) ||
            distanceToAlightingStop <= 600
        let phase: TransitCameraPhase = isApproachingStop
            ? (nextRide == nil ? .approachingDestination : .approachingTransfer)
            : .riding
        let focusAlightingStop = distanceToAlightingStop <= 300 ||
            (progress.stopsUntilAlighting.map { $0 <= 1 } ?? false)
        let nextStop = focusAlightingStop ? endStop : progress.nextStop ?? endStop
        let nextStopDistance = focusAlightingStop ? distanceToAlightingStop :
            progress.distanceToNextStop ?? nextStop.map { current.distance(to: $0.coordinate) }
        let stopInfluence = nextStopDistance.map { 1 - clamp($0 / 600, minimum: 0, maximum: 1) } ?? 0
        let isRail = ["RAIL", "TRAIN", "SUBURBAN", "SUBURBAN_RAIL"]
            .contains(leg.mode.uppercased())
        let lookAhead = 400 - 250 * stopInfluence
        let geometry = RouteProgressGeometry(coordinates: leg.coordinates)
        let routeBearing = geometry.bearing(at: progress.legDistance, lookAhead: max(100, lookAhead))
        let vehicle = vehicles
            .filter { ($0.tripID == leg.tripID || $0.routeID == leg.routeID) &&
                (-60...120).contains(now.timeIntervalSince($0.updatedAt)) }
            .min(by: { $0.coordinate.distance(to: current) < $1.coordinate.distance(to: current) })
        let bearing = routeBearing ?? vehicle?.bearing ?? previousBearing
        let routeTarget = geometry.coordinate(at: progress.legDistance + lookAhead) ?? current
        let target = nextStop.map { blend(routeTarget, $0.coordinate, stopInfluence) } ?? routeTarget

        var zoom = isRail ? 12.5 : 16.0
        var pitch = isRail ? 10.0 : 30.0
        if isRail {
            if distanceToAlightingStop <= 3_000 { zoom = 14 }
            if distanceToAlightingStop <= 1_000 { zoom = 15 }
            if distanceToAlightingStop <= 300 { zoom = 16.8; pitch = 15 }
        } else {
            if let stops = progress.stopsUntilAlighting {
                if stops <= 5 { zoom += 0.15 }
                if stops <= 2 { zoom += 0.2 }
                if stops <= 1 { zoom += 0.25 }
            }
            if distanceToAlightingStop <= 300 { zoom = 16.8; pitch = 20 }
        }

        return TransitCameraPlan(
            phase: phase,
            intent: CameraIntent(target: target, zoom: zoom, pitch: pitch, bearing: bearing,
                                 padding: .navigation))
    }

    private static func usableSpeed(_ location: NavigationLocation?) -> Double {
        guard let location, location.speed.isFinite,
              location.speedAccuracy < 0 || location.speedAccuracy <= 8 else { return 0 }
        return max(0, location.speed)
    }

    private static func usableCourse(_ location: NavigationLocation?, speed: Double) -> Double? {
        guard let location, speed > 1.2, location.course.isFinite,
              (0...360).contains(location.course),
              location.courseAccuracy < 0 || location.courseAccuracy <= 45 else { return nil }
        return location.course
    }

    private static func blend(_ start: Coordinate, _ end: Coordinate, _ weight: Double) -> Coordinate {
        let weight = clamp(weight, minimum: 0, maximum: 1)
        return Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * weight,
                          longitude: start.longitude + (end.longitude - start.longitude) * weight)
    }

    private static func shortestAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

/// Smooths pedestrian heading and selects a camera profile without putting
/// walking-specific behavior in either map adapter.
final class WalkingCameraController {
    private var lastMovementAt: Date?
    private var lastBearingUpdateAt: Date?
    private(set) var filteredBearing: Double?

    func reset() {
        lastMovementAt = nil
        lastBearingUpdateAt = nil
        filteredBearing = nil
    }

    func update(location: NavigationLocation?, deviceHeading _: Double?, now: Date = .now,
                isNewLocationFix: Bool = true) {
        guard let location else { return }
        let speedIsUsable = location.speed.isFinite && location.speed >= 0 &&
            (location.speedAccuracy < 0 || location.speedAccuracy <= 8)
        let speed = speedIsUsable ? location.speed : 0
        if isNewLocationFix && (speed > 0.8 || lastMovementAt == nil) { lastMovementAt = now }

        let gpsCourseIsUsable = speed > 1.2 && location.course.isFinite &&
            (0...360).contains(location.course) &&
            (location.courseAccuracy < 0 || location.courseAccuracy <= 45)
        // During an active walk, route geometry has priority. GPS course is a
        // fallback while moving; the device compass is intentionally ignored.
        let target = isNewLocationFix && gpsCourseIsUsable ? location.course : nil
        guard let target else { return }

        guard let current = filteredBearing else {
            filteredBearing = Self.normalized(target)
            lastBearingUpdateAt = now
            return
        }
        let elapsed = max(0, now.timeIntervalSince(lastBearingUpdateAt ?? now))
        guard elapsed > 0 else { return }
        let delta = Self.shortestAngle(from: current, to: target)
        let lowPassDelta = delta * (1 - exp(-elapsed / 0.9))
        let maximumDelta = 40 * elapsed
        filteredBearing = Self.normalized(current + min(maximumDelta, max(-maximumDelta, lowPassDelta)))
        lastBearingUpdateAt = now
    }

    func snapshot(at now: Date = .now) -> WalkingCameraSnapshot {
        WalkingCameraSnapshot(bearing: filteredBearing,
                              stoppedDuration: max(0, now.timeIntervalSince(lastMovementAt ?? now)))
    }

    static func profile(camera: NavigationCameraState, maneuverDistance: Double,
                        stoppedDuration: TimeInterval) -> WalkingCameraProfile {
        if stoppedDuration >= 3 {
            return WalkingCameraProfile(state: .stopped, zoom: 18.0,
                                        pitch: stoppedDuration >= 10 ? 12 : 25,
                                        lookAhead: 20, animationDuration: 0.6)
        }
        if camera == .leavingManeuver {
            return WalkingCameraProfile(state: .maneuver, zoom: 18.3, pitch: 22,
                                        lookAhead: 20, animationDuration: 0.8)
        }
        if camera == .approachingDestination {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 18.0, pitch: 28,
                                        lookAhead: 20, animationDuration: 0.6)
        }
        if camera == .maneuverNow || maneuverDistance <= 20 {
            return WalkingCameraProfile(state: .maneuver, zoom: 18.3, pitch: 20,
                                        lookAhead: max(20, min(30, maneuverDistance + 10)),
                                        animationDuration: camera == .startingNavigation ? 0.8 : 0.55)
        }
        if maneuverDistance <= 50 {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 18.1, pitch: 27,
                                        lookAhead: 20, animationDuration: 0.6)
        }
        if maneuverDistance <= 120 {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 17.9, pitch: 32,
                                        lookAhead: 28, animationDuration: 0.6)
        }
        if maneuverDistance > 300 {
            return WalkingCameraProfile(state: .cruising, zoom: 18.0, pitch: 30,
                                        lookAhead: 35, animationDuration: 0.65)
        }
        return WalkingCameraProfile(state: .cruising, zoom: 18.0, pitch: 30,
                                    lookAhead: 30, animationDuration: 0.6)
    }

    private static func shortestAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalized(_ value: Double) -> Double {
        (value + 360).truncatingRemainder(dividingBy: 360)
    }
}

struct RouteRevealGeometry {
    private let coordinates: [Coordinate]
    private let cumulativeDistances: [Double]
    private let length: Double

    init(coordinates: [Coordinate]) {
        self.coordinates = coordinates
        var distances = [0.0]
        distances.reserveCapacity(coordinates.count)
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            distances.append((distances.last ?? 0) + start.distance(to: end))
        }
        cumulativeDistances = distances
        length = distances.last ?? 0
    }

    func visibleCoordinates(progress: Double) -> [Coordinate] {
        guard coordinates.count > 1, length > 0 else { return coordinates }
        let fraction = max(0, min(1, progress))
        guard fraction < 1 else { return coordinates }
        guard fraction > 0 else { return [coordinates[0]] }

        let targetDistance = length * fraction
        var lower = 1
        var upper = cumulativeDistances.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulativeDistances[middle] < targetDistance { lower = middle + 1 }
            else { upper = middle }
        }
        let endIndex = lower
        let startDistance = cumulativeDistances[endIndex - 1]
        let segmentLength = cumulativeDistances[endIndex] - startDistance
        guard segmentLength > 0 else { return Array(coordinates.prefix(endIndex + 1)) }
        let amount = (targetDistance - startDistance) / segmentLength
        let start = coordinates[endIndex - 1]
        let end = coordinates[endIndex]
        let endpoint = Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * amount,
                                  longitude: start.longitude + (end.longitude - start.longitude) * amount)
        return Array(coordinates.prefix(endIndex)) + [endpoint]
    }
}

enum LocationAccuracyGeometry {
    static func circle(center: Coordinate, radiusMeters: Double, samples: Int = 48) -> [Coordinate] {
        guard radiusMeters > 0, samples >= 8 else { return [center] }
        let earthRadius = 6_371_000.0
        let angularDistance = radiusMeters / earthRadius
        let latitude = center.latitude * .pi / 180
        let longitude = center.longitude * .pi / 180

        return (0...samples).map { index in
            let bearing = 2 * .pi * Double(index) / Double(samples)
            let destinationLatitude = asin(
                sin(latitude) * cos(angularDistance) +
                    cos(latitude) * sin(angularDistance) * cos(bearing)
            )
            let destinationLongitude = longitude + atan2(
                sin(bearing) * sin(angularDistance) * cos(latitude),
                cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
            )
            return Coordinate(latitude: destinationLatitude * 180 / .pi,
                              longitude: destinationLongitude * 180 / .pi)
        }
    }
}

enum CameraPlanner {
    static func usableSpeed(from location: NavigationLocation?) -> Double {
        guard let location, location.speed.isFinite, location.speed >= 0,
              location.speedAccuracy < 0 ||
                (location.speedAccuracy.isFinite && location.speedAccuracy <= 8) else { return 0 }
        return location.speed
    }

    static func usableCourse(from location: NavigationLocation?, speed: Double) -> Double? {
        guard let location, speed >= 1.2, location.course.isFinite,
              (0..<360).contains(location.course),
              location.courseAccuracy < 0 ||
                (location.courseAccuracy.isFinite && location.courseAccuracy <= 35) else { return nil }
        return location.course
    }

    static func routeHeading(location: NavigationLocation?, route: NavigationRoute?,
                             projection: RouteProjection?) -> Double? {
        guard let location, let route, route.journey == nil,
              let projection = projection ?? MapMatcher.project(location.coordinate, onto: route.coordinates),
              isValidRouteProjection(projection, for: location),
              let pointAhead = pointAhead(of: location.coordinate, by: 18,
                                          on: route.coordinates, projection: projection) else { return nil }
        return bearing(from: projection.coordinate, to: pointAhead)
    }

    static func intent(for camera: NavigationCameraState, location: NavigationLocation?,
                       destination: Destination?, route: NavigationRoute?,
                       alternatives: [NavigationRoute], progress: RouteProgress?,
                       previousBearing: Double = 0,
                       precomputedRouteProjection: RouteProjection? = nil,
                       navigationBearing: Double? = nil,
                       navigationAnimationDuration: TimeInterval? = nil,
                       transportMode: TransportMode = .car,
                       walkingCamera: WalkingCameraSnapshot? = nil) -> CameraIntent? {
        guard let position = location?.coordinate ?? destination?.coordinate else { return nil }
        let speed = usableSpeed(from: location)
        switch camera {
        case .browse:
            return CameraIntent(target: position, zoom: 15.5, pitch: 0, bearing: 0, padding: .navigation)
        case .destinationPreview:
            guard let destination else { return nil }
            let bounds = location != nil && position.distance(to: destination.coordinate) >= 100
                ? [position, destination.coordinate] : []
            return CameraIntent(target: destination.coordinate, zoom: 15, pitch: 0, bearing: 0,
                                padding: .destination, bounds: bounds)
        case .routeOverview:
            guard let route else { return nil }
            let points = (alternatives + [route]).flatMap(\.coordinates)
            return CameraIntent(target: route.coordinates.last ?? position, zoom: 12, pitch: 0,
                                bearing: 0, padding: .route, bounds: points)
        case .freeLook:
            return nil
        case .startingNavigation, .followNavigation, .approachingManeuver, .maneuverNow,
             .leavingManeuver, .rerouting, .weakGPS, .approachingDestination:
            let isTransitRoute = route?.journey != nil
            let routeProjection: RouteProjection? = route.flatMap { route in
                guard route.journey == nil, let location,
                      let projection = precomputedRouteProjection ??
                        MapMatcher.project(position, onto: route.coordinates),
                      isValidRouteProjection(projection, for: location) else { return nil }
                return projection
            }
            let roadHeading = routeHeading(location: location, route: route, projection: routeProjection)
            let course = usableCourse(from: location, speed: speed) ?? previousBearing
            let usesWalkingCamera = transportMode == .walking && camera.usesNavigationPerspective
            let heading = usesWalkingCamera
                ? (navigationBearing ?? roadHeading ?? walkingCamera?.bearing ?? previousBearing)
                : (navigationBearing ?? roadHeading ?? course)
            let maneuverDistance = progress?.distanceToNextManeuver ?? .infinity
            let maneuver = progress?.nextManeuver
            let isRoundabout = maneuver?.kind.isRoundabout == true
            let isExit = maneuver?.kind.isExit == true
            let isComplexManeuver = Self.isComplex(maneuver?.kind)
            let walkingProfile = usesWalkingCamera
                ? WalkingCameraController.profile(camera: camera, maneuverDistance: maneuverDistance,
                                                  stoppedDuration: walkingCamera?.stoppedDuration ?? 0)
                : nil
            let speedKPH = speed * 3.6
            let followLookAhead = Self.interpolate(speedKPH, through: [
                (0, 45), (30, 80), (50, 150), (90, 300), (140, 500)
            ])
            let approachLookAhead = min(followLookAhead, maneuverDistance + (isComplexManeuver ? 55 : 40))
            let lookAhead: Double
            if let walkingProfile {
                lookAhead = walkingProfile.lookAhead
            } else {
                switch camera {
                case .approachingDestination: lookAhead = 35
                case .maneuverNow: lookAhead = min(100, max(20, maneuverDistance + 40))
                case .leavingManeuver: lookAhead = min(180, max(70, speed * 6))
                case .approachingManeuver:
                    lookAhead = isRoundabout ? min(130, maneuverDistance + 35) : approachLookAhead
                case .startingNavigation, .followNavigation, .rerouting, .weakGPS:
                    lookAhead = isRoundabout ? min(130, followLookAhead) : followLookAhead
                default: lookAhead = followLookAhead
                }
            }
            let target: Coordinate
            if walkingProfile?.state == .stopped {
                target = coordinateAhead(of: position, by: lookAhead, bearing: heading)
            } else if let route, route.journey == nil {
                target = routeProjection.flatMap {
                    pointAhead(of: position, by: lookAhead, on: route.coordinates, projection: $0)
                } ?? position
            } else {
                target = route.flatMap {
                    pointAhead(of: position, by: lookAhead, on: $0.coordinates, projection: routeProjection)
                } ?? position
            }
            let zoom: Double
            if let walkingProfile {
                zoom = walkingProfile.zoom
            } else {
                let cruisingZoom = Self.interpolate(speedKPH, through: [
                    (0, 17.1), (30, 17.0), (50, 16.6), (70, 16.0),
                    (100, 15.8), (120, 15.6), (140, 15.4)
                ])
                switch camera {
                case .approachingDestination: zoom = isTransitRoute ? 16.7 : 17.0
                case .maneuverNow: zoom = isTransitRoute ? 16.4 : (isComplexManeuver ? 18.0 : 17.7)
                case .leavingManeuver: zoom = isTransitRoute ? 15.9 : cruisingZoom
                case .approachingManeuver:
                    if isTransitRoute {
                        zoom = isRoundabout ? 15.6 : (isExit && maneuverDistance > 300 ? 15.8 : 16.2)
                    } else {
                        let urgency = max(0, min(1, 1 - maneuverDistance / (isExit ? 1_600 : 300)))
                        let targetZoom = isComplexManeuver ? 18.0 : 17.7
                        zoom = cruisingZoom + (targetZoom - cruisingZoom) * urgency
                    }
                case .startingNavigation, .followNavigation, .rerouting, .weakGPS:
                    if isTransitRoute {
                        zoom = isExit && maneuverDistance < 1_600 ? 15.8 : (speed > 25 ? 15.9 : 16.3)
                    } else {
                        zoom = camera == .weakGPS || camera == .rerouting
                            ? cruisingZoom - 0.25 : cruisingZoom
                    }
                default: zoom = 15.2
                }
            }
            let pitch: Double
            if let walkingProfile {
                pitch = walkingProfile.pitch
            } else {
                let cruisingPitch = Self.interpolate(speedKPH, through: [
                    (0, 42), (30, 46), (50, 50), (70, 52), (100, 56), (140, 58)
                ])
                switch camera {
                case .maneuverNow: pitch = isComplexManeuver ? 39 : 43
                case .approachingManeuver:
                    if isTransitRoute {
                        pitch = 46
                    } else {
                        let urgency = max(0, min(1, 1 - maneuverDistance / (isExit ? 1_600 : 300)))
                        pitch = max(38, cruisingPitch - urgency * 8 - (isComplexManeuver ? 3 : 0))
                    }
                case .leavingManeuver: pitch = cruisingPitch
                case .approachingDestination: pitch = 40
                case .rerouting, .weakGPS: pitch = 44
                default: pitch = cruisingPitch
                }
            }
            return CameraIntent(target: target, zoom: zoom, pitch: pitch, bearing: heading,
                                padding: .navigation,
                                animationDuration: camera == .startingNavigation
                                    ? 0.65 : walkingProfile?.animationDuration ?? navigationAnimationDuration)
        case .arrived:
            let points = [position, destination?.coordinate].compactMap { $0 }
            let bounds = points.count == 2 && points[0].distance(to: points[1]) >= 100 ? points : []
            return CameraIntent(target: destination?.coordinate ?? position, zoom: 15, pitch: 35,
                                bearing: 0, padding: .destination, bounds: bounds)
        }
    }

    static func predictedLocation(from location: NavigationLocation, elapsed: TimeInterval,
                                  route: NavigationRoute?) -> NavigationLocation {
        guard let route, location.speed > 0,
              let coordinate = pointAhead(of: location.coordinate, by: min(15, elapsed) * location.speed,
                                          on: route.coordinates) else { return location }
        return NavigationLocation(coordinate: coordinate, speed: location.speed, course: location.course,
                                  accuracy: location.accuracy + elapsed * 3, timestamp: location.timestamp,
                                  speedAccuracy: location.speedAccuracy, courseAccuracy: location.courseAccuracy)
    }

    static func revealedCoordinates(_ coordinates: [Coordinate], progress: Double) -> [Coordinate] {
        guard coordinates.count > 1 else { return coordinates }
        let fraction = max(0, min(1, progress))
        if fraction >= 1 { return coordinates }
        let segmentLengths = zip(coordinates, coordinates.dropFirst()).map { $0.0.distance(to: $0.1) }
        var remaining = segmentLengths.reduce(0, +) * fraction
        var result = [coordinates[0]]
        for index in segmentLengths.indices {
            let length = segmentLengths[index]
            if length <= remaining {
                result.append(coordinates[index + 1])
                remaining -= length
            } else {
                if length > 0 {
                    let part = remaining / length
                    let a = coordinates[index], b = coordinates[index + 1]
                    result.append(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * part,
                                             longitude: a.longitude + (b.longitude - a.longitude) * part))
                }
                break
            }
        }
        return result
    }

    private static func pointAhead(of position: Coordinate, by meters: Double, on route: [Coordinate],
                                   projection: RouteProjection? = nil) -> Coordinate? {
        guard let projection = projection ?? MapMatcher.project(position, onto: route),
              projection.segment + 1 < route.count else { return nil }
        var remaining = meters
        var current = projection.coordinate
        for next in route[(projection.segment + 1)...] {
            let length = current.distance(to: next)
            if length >= remaining, length > 0 {
                let fraction = remaining / length
                return Coordinate(latitude: current.latitude + (next.latitude - current.latitude) * fraction,
                                  longitude: current.longitude + (next.longitude - current.longitude) * fraction)
            }
            remaining -= length
            current = next
        }
        return route.last
    }

    private static func isComplex(_ kind: ManeuverKind?) -> Bool {
        guard let kind else { return false }
        switch kind {
        case .roundaboutEnter, .roundaboutExit, .rampStraight, .rampRight, .rampLeft,
             .exitRight, .exitLeft, .sharpRight, .sharpLeft, .uTurnRight, .uTurnLeft:
            return true
        default:
            return false
        }
    }

    private static func isValidRouteProjection(_ projection: RouteProjection,
                                               for location: NavigationLocation) -> Bool {
        guard projection.distanceFromRoute.isFinite else { return false }
        let accuracy = location.accuracy.isFinite ? max(0, location.accuracy) : 0
        return projection.distanceFromRoute <= max(45, min(100, accuracy * 2.5))
    }

    private static func interpolate(_ value: Double, through stops: [(Double, Double)]) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if value <= first.0 { return first.1 }
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.0 {
            let span = upper.0 - lower.0
            guard span > 0 else { return upper.1 }
            let fraction = (value - lower.0) / span
            return lower.1 + (upper.1 - lower.1) * fraction
        }
        return last.1
    }

    private static func bearing(from start: Coordinate, to end: Coordinate) -> Double? {
        let longitudeDelta = ((end.longitude - start.longitude + 540)
            .truncatingRemainder(dividingBy: 360) - 180) * cos(start.latitude * .pi / 180)
        let latitudeDelta = end.latitude - start.latitude
        guard longitudeDelta.isFinite, latitudeDelta.isFinite,
              hypot(longitudeDelta, latitudeDelta) > 0 else { return nil }
        return (atan2(longitudeDelta, latitudeDelta) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    private static func coordinateAhead(of position: Coordinate, by meters: Double,
                                        bearing: Double) -> Coordinate {
        guard meters > 0 else { return position }
        let angularDistance = meters / 6_371_000
        let heading = bearing * .pi / 180
        let latitude = position.latitude * .pi / 180
        let longitude = position.longitude * .pi / 180
        let destinationLatitude = asin(sin(latitude) * cos(angularDistance) +
                                       cos(latitude) * sin(angularDistance) * cos(heading))
        let destinationLongitude = longitude + atan2(
            sin(heading) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude))
        return Coordinate(latitude: destinationLatitude * 180 / .pi,
                          longitude: destinationLongitude * 180 / .pi)
    }
}
