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

    func update(location: NavigationLocation?, deviceHeading: Double?, now: Date = .now,
                isNewLocationFix: Bool = true) {
        guard let location else { return }
        let speedIsUsable = location.speed.isFinite && location.speed >= 0 &&
            (location.speedAccuracy < 0 || location.speedAccuracy <= 8)
        let speed = speedIsUsable ? location.speed : 0
        if isNewLocationFix && (speed > 0.8 || lastMovementAt == nil) { lastMovementAt = now }

        let gpsCourseIsUsable = speed > 1.2 && location.course.isFinite &&
            (0...360).contains(location.course) &&
            (location.courseAccuracy < 0 || location.courseAccuracy <= 45)
        let headingIsUsable = deviceHeading.map { $0.isFinite && (0...360).contains($0) } ?? false
        let target = isNewLocationFix && gpsCourseIsUsable ? location.course :
            (headingIsUsable ? deviceHeading : nil)
        guard let target else { return }

        guard let current = filteredBearing else {
            filteredBearing = Self.normalized(target)
            lastBearingUpdateAt = now
            return
        }
        let elapsed = max(0, now.timeIntervalSince(lastBearingUpdateAt ?? now))
        guard elapsed > 0 else { return }
        let delta = Self.shortestAngle(from: current, to: target)
        let lowPassDelta = delta * (1 - exp(-elapsed / 0.45))
        let maximumDelta = 60 * elapsed
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
            return WalkingCameraProfile(state: .stopped, zoom: 17.8,
                                        pitch: stoppedDuration >= 10 ? 12 : 25,
                                        lookAhead: 20, animationDuration: 0.6)
        }
        if camera == .leavingManeuver {
            return WalkingCameraProfile(state: .maneuver, zoom: 18.1, pitch: 27,
                                        lookAhead: 20, animationDuration: 0.8)
        }
        if camera == .approachingDestination {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 17.5, pitch: 35,
                                        lookAhead: 18, animationDuration: 0.6)
        }
        if camera == .maneuverNow || maneuverDistance <= 20 {
            return WalkingCameraProfile(state: .maneuver, zoom: 18.1, pitch: 27,
                                        lookAhead: max(5, min(18, maneuverDistance - 2)),
                                        animationDuration: camera == .startingNavigation ? 0.8 : 0.55)
        }
        if maneuverDistance <= 50 {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 17.8, pitch: 32,
                                        lookAhead: 18, animationDuration: 0.6)
        }
        if maneuverDistance <= 120 {
            return WalkingCameraProfile(state: .approachingTurn, zoom: 17.5, pitch: 38,
                                        lookAhead: 22, animationDuration: 0.6)
        }
        if maneuverDistance > 300 {
            return WalkingCameraProfile(state: .cruising, zoom: 17.0, pitch: 43,
                                        lookAhead: 25, animationDuration: 0.65)
        }
        return WalkingCameraProfile(state: .cruising, zoom: 17.2, pitch: 40,
                                    lookAhead: 22, animationDuration: 0.6)
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
    static func intent(for camera: NavigationCameraState, location: NavigationLocation?,
                       destination: Destination?, route: NavigationRoute?,
                       alternatives: [NavigationRoute], progress: RouteProgress?,
                       previousBearing: Double = 0,
                       precomputedRouteProjection: RouteProjection? = nil,
                       transportMode: TransportMode = .car,
                       walkingCamera: WalkingCameraSnapshot? = nil) -> CameraIntent? {
        guard let position = location?.coordinate ?? destination?.coordinate else { return nil }
        let speed = max(0, location?.speed ?? 0)
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
            let routeProjection = route.flatMap {
                precomputedRouteProjection ?? ($0.journey == nil
                    ? MapMatcher.project(position, onto: $0.coordinates)
                    : nil)
            }
            let roadHeading: Double? = route.flatMap { route in
                guard let projection = routeProjection,
                      projection.segment + 1 < route.coordinates.count else { return nil }
                let a = route.coordinates[projection.segment], b = route.coordinates[projection.segment + 1]
                let radians = atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180),
                                    b.latitude - a.latitude)
                return (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            }
            let course = location.flatMap { $0.course >= 0 ? $0.course : nil } ?? previousBearing
            let usesWalkingCamera = transportMode == .walking && camera.usesNavigationPerspective
            let heading = usesWalkingCamera
                ? (walkingCamera?.bearing ?? roadHeading ?? previousBearing)
                : (camera == .startingNavigation || speed > 0.85
                    ? (roadHeading ?? course)
                    : previousBearing)
            let maneuverDistance = progress?.distanceToNextManeuver ?? .infinity
            let maneuver = progress?.nextManeuver
            let isRoundabout = maneuver?.kind.isRoundabout == true
            let isExit = maneuver?.kind.isExit == true
            let walkingProfile = usesWalkingCamera
                ? WalkingCameraController.profile(camera: camera, maneuverDistance: maneuverDistance,
                                                  stoppedDuration: walkingCamera?.stoppedDuration ?? 0)
                : nil
            let followLookAhead = min(350, max(80, speed * 8))
            let approachLookAhead = min(min(300, max(80, speed * 7)), maneuverDistance + 45)
            let lookAhead: Double
            if let walkingProfile {
                lookAhead = walkingProfile.lookAhead
            } else {
                switch camera {
                case .approachingDestination: lookAhead = 35
                case .maneuverNow: lookAhead = maneuverDistance + 35
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
            } else {
                target = route.flatMap {
                    pointAhead(of: position, by: lookAhead, on: $0.coordinates, projection: routeProjection)
                } ?? position
            }
            let zoom: Double
            if let walkingProfile {
                zoom = walkingProfile.zoom
            } else {
                switch camera {
                case .approachingDestination: zoom = isTransitRoute ? 16.7 : 16.3
                case .maneuverNow: zoom = isTransitRoute ? 16.4 : 16.0
                case .leavingManeuver: zoom = isTransitRoute ? 15.9 : 15.2
                case .approachingManeuver:
                    if isRoundabout { zoom = isTransitRoute ? 15.6 : 15.0 }
                    else if isExit && maneuverDistance > 300 { zoom = isTransitRoute ? 15.8 : 14.6 }
                    else if maneuverDistance <= 100 { zoom = isTransitRoute ? 16.2 : 15.8 }
                    else { zoom = isTransitRoute ? 15.9 : 15.2 }
                case .startingNavigation, .followNavigation, .rerouting, .weakGPS:
                    if isTransitRoute {
                        zoom = isExit && maneuverDistance < 1_600 ? 15.8 : (speed > 25 ? 15.9 : 16.3)
                    } else {
                        zoom = isExit && maneuverDistance < 1_600 ? 14.6 : (speed > 25 ? 14.2 : 15.6)
                    }
                default: zoom = 15.2
                }
            }
            let pitch: Double
            if let walkingProfile {
                pitch = walkingProfile.pitch
            } else {
                switch camera {
                case .maneuverNow: pitch = 38
                case .approachingManeuver, .leavingManeuver: pitch = 46
                case .approachingDestination: pitch = 40
                case .rerouting, .weakGPS: pitch = 42
                default: pitch = 55
                }
            }
            return CameraIntent(target: target, zoom: zoom, pitch: pitch, bearing: heading,
                                padding: .navigation,
                                animationDuration: camera == .startingNavigation
                                    ? 0.35 : walkingProfile?.animationDuration)
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
