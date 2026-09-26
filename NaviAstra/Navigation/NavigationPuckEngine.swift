import CoreLocation
import Foundation

struct NavigationPuckFrame {
    let coordinate: Coordinate
    let bearing: CLLocationDirection?
    let routeProgress: Double?
}

/// Produces a display position independently from the GPS fixes used by navigation logic.
@MainActor
final class NavigationPuckEngine {
    private struct RouteGeometry {
        let id: UUID
        let coordinates: [Coordinate]
        let cumulativeDistances: [Double]
        let length: Double

        init(_ route: NavigationRoute) {
            id = route.id
            coordinates = route.coordinates
            var distances = [0.0]
            distances.reserveCapacity(coordinates.count)
            for (start, end) in zip(coordinates, coordinates.dropFirst()) {
                distances.append((distances.last ?? 0) + start.distance(to: end))
            }
            cumulativeDistances = distances
            length = distances.last ?? 0
        }

        func coordinate(at distance: Double) -> Coordinate {
            guard coordinates.count > 1, length > 0 else { return coordinates.first ?? Coordinate(latitude: 0, longitude: 0) }
            let value = min(length, max(0, distance))
            let index = segmentIndex(at: value)
            let segmentStart = cumulativeDistances[index]
            let segmentLength = cumulativeDistances[index + 1] - segmentStart
            guard segmentLength > 0 else { return coordinates[index] }
            let fraction = (value - segmentStart) / segmentLength
            let start = coordinates[index]
            let end = coordinates[index + 1]
            return Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                              longitude: start.longitude + (end.longitude - start.longitude) * fraction)
        }

        func bearing(at distance: Double) -> CLLocationDirection? {
            guard coordinates.count > 1, length > 0 else { return nil }
            let index = segmentIndex(at: min(length, max(0, distance)))
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let dx = (end.longitude - start.longitude) * cos(start.latitude * .pi / 180)
            let dy = end.latitude - start.latitude
            guard hypot(dx, dy) > 0 else { return nil }
            return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }

        private func segmentIndex(at distance: Double) -> Int {
            var low = 0
            var high = max(0, cumulativeDistances.count - 2)
            while low < high {
                let middle = (low + high) / 2
                if cumulativeDistances[middle + 1] < distance { low = middle + 1 }
                else { high = middle }
            }
            return min(low, max(0, coordinates.count - 2))
        }
    }

    private let maximumPredictionDuration: TimeInterval = 2
    private let correctionDuration: TimeInterval = 0.32
    private let bearingSmoothingDuration: TimeInterval = 0.16
    private var geometry: RouteGeometry?
    private var lastInputTimestamp: Date?
    private var lastInputRouteID: UUID?
    private var lastInputWasNavigating = false
    private var previousProjection: RouteProjection?
    private var previousProjectionTimestamp: Date?

    private var anchorTime = Date.distantPast
    private var anchorCoordinate: Coordinate?
    private var anchorProgress: Double?
    private var anchorSpeed: CLLocationSpeed = 0
    private var anchorCourse: CLLocationDirection?
    private var routeCorrection = 0.0
    private var directCorrectionEast = 0.0
    private var directCorrectionNorth = 0.0
    private var lastFrameTime: Date?
    private var smoothedBearing: CLLocationDirection?

    func update(location: NavigationLocation?, route: NavigationRoute?, isNavigating: Bool,
                at now: Date = Date()) {
        guard let location else { return }
        let activeRoute = isNavigating ? route : nil
        let routeID = activeRoute?.id
        guard location.timestamp != lastInputTimestamp || routeID != lastInputRouteID ||
                isNavigating != lastInputWasNavigating else { return }

        let oldFrame = frame(at: now)
        let routeChanged = routeID != geometry?.id
        if routeChanged {
            geometry = activeRoute.map(RouteGeometry.init)
            previousProjection = nil
            previousProjectionTimestamp = nil
        }

        let isSameRoute = routeID != nil && routeID == lastInputRouteID && !routeChanged
        let projectedMatch = geometry.flatMap { geometry -> RouteMatch? in
            guard isNavigating else { return nil }
            return MapMatcher.match(location, onto: geometry.coordinates,
                                    previous: isSameRoute ? previousProjection : nil,
                                    previousTimestamp: isSameRoute ? previousProjectionTimestamp : nil)
        }
        let maximumMatchDistance = max(45, min(100, location.accuracy * 2.5))
        let acceptedMatch = projectedMatch.flatMap {
            $0.projection.distanceFromRoute <= maximumMatchDistance ? $0 : nil
        }
        let closeProjection = geometry.flatMap { geometry -> RouteProjection? in
            guard isNavigating else { return nil }
            guard let projection = MapMatcher.project(location.coordinate, onto: geometry.coordinates) else {
                return nil
            }
            return projection.distanceFromRoute <= maximumMatchDistance
                ? projection : nil
        }
        let routeProjection = acceptedMatch?.projection ?? closeProjection
        if let routeProjection {
            previousProjection = routeProjection
            previousProjectionTimestamp = location.timestamp
        } else if !isSameRoute {
            previousProjection = nil
            previousProjectionTimestamp = nil
        }

        let usableSpeed = Self.usableSpeed(from: location)
        let usableCourse = Self.usableCourse(from: location, speed: usableSpeed)
        let accuracyWeight = Self.accuracyWeight(location.accuracy)
        let matchWeight = acceptedMatch.map { min(1, max(0.2, $0.confidence)) } ?? 1
        let correctionWeight = 0.75 * accuracyWeight + 0.25 * matchWeight

        if let oldFrame {
            if let routeProjection, let geometry {
                let currentProgress: Double
                if routeChanged {
                    if let oldProjection = MapMatcher.project(oldFrame.coordinate, onto: geometry.coordinates),
                       oldProjection.distanceFromRoute <= 150 {
                        currentProgress = oldProjection.alongRoute
                    } else {
                        currentProgress = routeProjection.alongRoute
                    }
                } else if let oldProgress = oldFrame.routeProgress {
                    currentProgress = oldProgress
                } else {
                    if let oldProjection = MapMatcher.project(oldFrame.coordinate, onto: geometry.coordinates),
                       oldProjection.distanceFromRoute <= 150 {
                        currentProgress = oldProjection.alongRoute
                    } else {
                        currentProgress = routeProjection.alongRoute
                    }
                }
                anchorProgress = currentProgress
                routeCorrection = min(120, max(-120, routeProjection.alongRoute - currentProgress)) * correctionWeight
                anchorCoordinate = nil
                directCorrectionEast = 0
                directCorrectionNorth = 0
            } else {
                anchorCoordinate = oldFrame.coordinate
                anchorProgress = nil
                routeCorrection = 0
                let delta = Self.localDelta(from: oldFrame.coordinate, to: location.coordinate)
                let maxCorrection = max(12, min(80, location.accuracy * 2))
                let length = hypot(delta.east, delta.north)
                let scale = length > maxCorrection ? maxCorrection / length : 1
                directCorrectionEast = delta.east * scale * correctionWeight
                directCorrectionNorth = delta.north * scale * correctionWeight
            }
            anchorCourse = usableCourse ?? oldFrame.bearing ?? smoothedBearing
        } else {
            anchorCoordinate = location.coordinate
            anchorProgress = routeProjection?.alongRoute
            routeCorrection = 0
            directCorrectionEast = 0
            directCorrectionNorth = 0
            anchorCourse = usableCourse ?? routeProjection.flatMap { geometry?.bearing(at: $0.alongRoute) }
            smoothedBearing = anchorCourse
        }

        if routeChanged, let routeProjection, oldFrame == nil {
            anchorCoordinate = nil
            anchorProgress = routeProjection.alongRoute
        }
        anchorSpeed = usableSpeed
        anchorTime = now
        lastInputTimestamp = location.timestamp
        lastInputRouteID = routeID
        lastInputWasNavigating = isNavigating
    }

    func frame(at now: Date = Date()) -> NavigationPuckFrame? {
        guard anchorTime != .distantPast else { return nil }
        let elapsed = max(0, now.timeIntervalSince(anchorTime))
        let prediction = min(maximumPredictionDuration, elapsed)
        let correctionFraction = Self.easeOut(min(1, max(0, elapsed / correctionDuration)))
        let routeProgress: Double?
        let coordinate: Coordinate
        let targetBearing: CLLocationDirection?

        if let geometry, let anchorProgress {
            let progress = min(geometry.length, max(0,
                anchorProgress + anchorSpeed * prediction + routeCorrection * correctionFraction))
            routeProgress = progress
            coordinate = geometry.coordinate(at: progress)
            targetBearing = geometry.bearing(at: progress) ?? anchorCourse
        } else if let anchorCoordinate {
            routeProgress = nil
            let movement = anchorCourse == nil ? 0 : anchorSpeed * prediction
            let moved = Self.destination(from: anchorCoordinate, distance: movement,
                                         bearing: anchorCourse ?? smoothedBearing ?? 0)
            coordinate = Self.destination(from: moved,
                                          east: directCorrectionEast * correctionFraction,
                                          north: directCorrectionNorth * correctionFraction)
            targetBearing = anchorSpeed > 0.8 ? anchorCourse : smoothedBearing ?? anchorCourse
        } else {
            return nil
        }

        let deltaTime = lastFrameTime.map { max(0, now.timeIntervalSince($0)) } ?? 0
        if let targetBearing {
            if let smoothedBearing, deltaTime > 0 {
                let factor = 1 - exp(-deltaTime / bearingSmoothingDuration)
                self.smoothedBearing = Self.smoothAngle(current: smoothedBearing,
                                                        target: targetBearing, factor: factor)
            } else {
                smoothedBearing = targetBearing
            }
        }
        lastFrameTime = now
        return NavigationPuckFrame(coordinate: coordinate, bearing: smoothedBearing,
                                   routeProgress: routeProgress)
    }

    private static func usableSpeed(from location: NavigationLocation) -> CLLocationSpeed {
        guard location.speed.isFinite, location.speed >= 0,
              location.speedAccuracy < 0 || location.speedAccuracy <= 8 else { return 0 }
        return min(location.speed, 85)
    }

    private static func usableCourse(from location: NavigationLocation,
                                     speed: CLLocationSpeed) -> CLLocationDirection? {
        guard speed > 0.8, location.course.isFinite, location.course >= 0,
              location.course <= 360,
              location.courseAccuracy < 0 || location.courseAccuracy <= 45 else { return nil }
        return normalized(location.course)
    }

    private static func accuracyWeight(_ accuracy: CLLocationAccuracy) -> Double {
        guard accuracy.isFinite, accuracy >= 0 else { return 0.5 }
        if accuracy < 8 { return 0.9 }
        if accuracy < 20 { return 0.7 }
        if accuracy < 40 { return 0.4 }
        return 0.15
    }

    private static func localDelta(from start: Coordinate, to end: Coordinate) -> (east: Double, north: Double) {
        let latitude = (start.latitude + end.latitude) * 0.5 * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        return (longitudeDelta * 111_320 * cos(latitude),
                (end.latitude - start.latitude) * 110_574)
    }

    private static func destination(from coordinate: Coordinate, distance: Double,
                                    bearing: CLLocationDirection) -> Coordinate {
        guard distance > 0 else { return coordinate }
        let earthRadius = 6_371_000.0
        let angularDistance = distance / earthRadius
        let bearingRadians = bearing * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let destinationLatitude = asin(sin(latitude) * cos(angularDistance) +
                                      cos(latitude) * sin(angularDistance) * cos(bearingRadians))
        let destinationLongitude = longitude + atan2(
            sin(bearingRadians) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude))
        return Coordinate(latitude: destinationLatitude * 180 / .pi,
                          longitude: (destinationLongitude * 180 / .pi + 540)
                            .truncatingRemainder(dividingBy: 360) - 180)
    }

    private static func destination(from coordinate: Coordinate, east: Double, north: Double) -> Coordinate {
        let distance = hypot(east, north)
        guard distance > 0 else { return coordinate }
        return destination(from: coordinate, distance: distance,
                           bearing: atan2(east, north) * 180 / .pi)
    }

    private static func smoothAngle(current: Double, target: Double, factor: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return normalized(current + delta * factor)
    }

    private static func normalized(_ angle: Double) -> Double {
        (angle + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func easeOut(_ value: Double) -> Double { 1 - pow(1 - value, 3) }
}
