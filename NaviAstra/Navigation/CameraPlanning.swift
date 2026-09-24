import Foundation

/// The navigation engine owns the state and intent. Map adapters only animate it.
enum NavigationCameraState: Equatable {
    case browse, destinationPreview, routeOverview, startingNavigation
    case followNavigation, approachingManeuver, maneuverNow, leavingManeuver, freeLook, rerouting
    case weakGPS, approachingDestination, arrived
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
                       previousBearing: Double = 0) -> CameraIntent? {
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
            let routeProjection = route.flatMap { MapMatcher.project(position, onto: $0.coordinates) }
            let roadHeading: Double? = route.flatMap { route in
                guard let projection = routeProjection,
                      projection.segment + 1 < route.coordinates.count else { return nil }
                let a = route.coordinates[projection.segment], b = route.coordinates[projection.segment + 1]
                let radians = atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180),
                                    b.latitude - a.latitude)
                return (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            }
            let course = location.flatMap { $0.course >= 0 ? $0.course : nil } ?? previousBearing
            let heading = camera == .startingNavigation || speed > 0.85
                ? (roadHeading ?? course)
                : previousBearing
            let maneuverDistance = progress?.distanceToNextManeuver ?? .infinity
            let maneuver = progress?.nextManeuver
            let isRoundabout = maneuver?.kind.isRoundabout == true
            let isExit = maneuver?.kind.isExit == true
            let followLookAhead = min(350, max(80, speed * 8))
            let approachLookAhead = min(min(300, max(80, speed * 7)), maneuverDistance + 45)
            let lookAhead: Double
            switch camera {
            case .approachingDestination: lookAhead = 35
            case .maneuverNow: lookAhead = maneuverDistance + 35
            case .leavingManeuver: lookAhead = min(180, max(70, speed * 6))
            case .approachingManeuver: lookAhead = isRoundabout ? min(130, maneuverDistance + 35) : approachLookAhead
            case .startingNavigation, .followNavigation, .rerouting, .weakGPS:
                lookAhead = isRoundabout ? min(130, followLookAhead) : followLookAhead
            default: lookAhead = followLookAhead
            }
            let target = route.flatMap {
                pointAhead(of: position, by: lookAhead, on: $0.coordinates, projection: routeProjection)
            } ?? position
            let zoom: Double
            switch camera {
            case .approachingDestination: zoom = 16.3
            case .maneuverNow: zoom = 16.0
            case .leavingManeuver: zoom = 15.2
            case .approachingManeuver:
                if isRoundabout { zoom = 15.0 }
                else if isExit && maneuverDistance > 300 { zoom = 14.6 }
                else if maneuverDistance <= 100 { zoom = 15.8 }
                else { zoom = 15.2 }
            case .startingNavigation, .followNavigation, .rerouting, .weakGPS:
                zoom = isExit && maneuverDistance < 1_600 ? 14.6 : (speed > 25 ? 14.2 : 15.6)
            default: zoom = 15.2
            }
            let pitch: Double
            switch camera {
            case .maneuverNow: pitch = 38
            case .approachingManeuver, .leavingManeuver: pitch = 46
            case .approachingDestination: pitch = 40
            case .rerouting, .weakGPS: pitch = 42
            default: pitch = 55
            }
            return CameraIntent(target: target, zoom: zoom, pitch: pitch, bearing: heading,
                                padding: .navigation)
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
                                  accuracy: location.accuracy + elapsed * 3, timestamp: location.timestamp)
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
}
