import Foundation

nonisolated struct RouteProjection: Sendable {
    let coordinate: Coordinate
    let distanceFromRoute: Double
    let alongRoute: Double
    let segment: Int
}

nonisolated enum MapMatcher {
    nonisolated static func project(_ location: Coordinate, onto route: [Coordinate]) -> RouteProjection? {
        guard route.count > 1 else { return nil }
        let metersPerLatitudeDegree = 110_574.0
        let metersPerLongitudeDegreeAtLocation = 111_320.0 * cos(location.latitude * .pi / 180)
        var bestCoordinate: Coordinate?
        var bestDistanceSquared = Double.infinity
        var bestAlongRoute = 0.0
        var bestSegment = 0
        var traveled = 0.0
        for index in 0..<(route.count - 1) {
            let a = route[index], b = route[index + 1]
            let longitudeDelta = b.longitude - a.longitude
            let latitudeDelta = b.latitude - a.latitude
            let dx = longitudeDelta * metersPerLongitudeDegreeAtLocation
            let dy = latitudeDelta * metersPerLatitudeDegree
            let px = (location.longitude - a.longitude) * metersPerLongitudeDegreeAtLocation
            let py = (location.latitude - a.latitude) * metersPerLatitudeDegree
            let segmentLengthSquared = dx * dx + dy * dy
            guard segmentLengthSquared > 0 else { continue }
            let segmentLength = sqrt(segmentLengthSquared)
            let fraction = max(0, min(1, (px * dx + py * dy) / segmentLengthSquared))
            let offsetX = px - fraction * dx
            let offsetY = py - fraction * dy
            let distanceSquared = offsetX * offsetX + offsetY * offsetY
            let projected = Coordinate(latitude: a.latitude + fraction * (b.latitude - a.latitude),
                                       longitude: a.longitude + fraction * (b.longitude - a.longitude))
            if distanceSquared < bestDistanceSquared {
                bestCoordinate = projected
                bestDistanceSquared = distanceSquared
                bestAlongRoute = traveled + fraction * segmentLength
                bestSegment = index
            }
            traveled += segmentLength
        }
        guard let bestCoordinate else { return nil }
        return RouteProjection(coordinate: bestCoordinate, distanceFromRoute: sqrt(bestDistanceSquared),
                               alongRoute: bestAlongRoute, segment: bestSegment)
    }

    static func match(_ location: NavigationLocation, onto route: [Coordinate],
                      previous: RouteProjection? = nil, previousTimestamp: Date? = nil) -> RouteMatch? {
        guard route.count > 1 else { return nil }
        let accuracy = max(8, location.accuracy)
        let elapsed = previousTimestamp.map { max(0, location.timestamp.timeIntervalSince($0)) } ?? 0
        let expectedProgress = previous.map { $0.alongRoute + max(0, location.speed) * elapsed }
        var bestProjection: RouteProjection?
        var bestScore = Double.infinity
        var traveled = 0.0
        let metersPerLatitudeDegree = 110_574.0
        let metersPerLongitudeDegree = 111_320.0 * cos(location.coordinate.latitude * .pi / 180)
        for index in 0..<(route.count - 1) {
            let start = route[index], end = route[index + 1]
            let dx = (end.longitude - start.longitude) * metersPerLongitudeDegree
            let dy = (end.latitude - start.latitude) * metersPerLatitudeDegree
            let segmentLengthSquared = dx * dx + dy * dy
            guard segmentLengthSquared > 0 else { continue }
            let segmentLength = sqrt(segmentLengthSquared)
            let px = (location.coordinate.longitude - start.longitude) * metersPerLongitudeDegree
            let py = (location.coordinate.latitude - start.latitude) * metersPerLatitudeDegree
            let fraction = max(0, min(1, (px * dx + py * dy) / segmentLengthSquared))
            let offsetX = px - fraction * dx
            let offsetY = py - fraction * dy
            let coordinate = Coordinate(
                latitude: start.latitude + fraction * (end.latitude - start.latitude),
                longitude: start.longitude + fraction * (end.longitude - start.longitude))
            let projection = RouteProjection(coordinate: coordinate,
                                             distanceFromRoute: hypot(offsetX, offsetY),
                                             alongRoute: traveled + fraction * segmentLength,
                                             segment: index)
            if projection.distanceFromRoute <= max(250, location.accuracy * 6) {
                let bearing = atan2(dx, dy) * 180 / .pi
                let normalizedBearing = (bearing + 360).truncatingRemainder(dividingBy: 360)
                let distanceScore = pow(projection.distanceFromRoute / accuracy, 2)
                var score = distanceScore
                if location.speed >= 1.5, location.course >= 0, location.course <= 360 {
                    let difference = abs(location.course - normalizedBearing)
                    let headingDifference = min(difference, 360 - difference)
                    score += pow(headingDifference / 55, 2)
                }
                if let expectedProgress {
                    let continuityScale = max(35, max(0, location.speed) * elapsed + accuracy * 2)
                    score += pow((projection.alongRoute - expectedProgress) / continuityScale, 2) * 0.35
                }
                if score < bestScore {
                    bestProjection = projection
                    bestScore = score
                }
            }
            traveled += segmentLength
        }
        guard let bestProjection else { return nil }
        return RouteMatch(projection: bestProjection, confidence: exp(-0.5 * min(40, bestScore)))
    }
}

nonisolated struct RouteMatch: Sendable {
    let projection: RouteProjection
    let confidence: Double
}

nonisolated struct NavigationRouteMatch: Sendable {
    let routeID: UUID
    let locationTimestamp: Date
    let match: RouteMatch
}

struct RouteProgressGeometry {
    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    private static let cellSize = 0.01
    private static let indexedProjectionRadius = 500.0

    let routeID: UUID?
    let coordinates: [Coordinate]
    private let segmentLengths: [Double]
    let cumulativeDistances: [Double]
    let length: Double
    private let segmentIndicesByCell: [Cell: [Int]]
    private let unindexedSegments: [Int]

    init(_ route: NavigationRoute) {
        self.init(routeID: route.id, coordinates: route.coordinates)
    }

    init(coordinates: [Coordinate]) {
        self.init(routeID: nil, coordinates: coordinates)
    }

    private init(routeID: UUID?, coordinates: [Coordinate]) {
        self.routeID = routeID
        self.coordinates = coordinates
        var lengths: [Double] = []
        var distances = [0.0]
        lengths.reserveCapacity(max(0, coordinates.count - 1))
        distances.reserveCapacity(coordinates.count)
        var cellSegments: [Cell: [Int]] = [:]
        var unindexed: [Int] = []
        for (index, pair) in zip(coordinates, coordinates.dropFirst()).enumerated() {
            let (start, end) = pair
            let segmentLength = start.distance(to: end)
            lengths.append(segmentLength)
            distances.append((distances.last ?? 0) + segmentLength)
            if !Self.index(segment: index, from: start, to: end, in: &cellSegments) {
                unindexed.append(index)
            }
        }
        segmentLengths = lengths
        cumulativeDistances = distances
        length = distances.last ?? 0
        segmentIndicesByCell = cellSegments
        unindexedSegments = unindexed
    }

    func distance(from startIndex: Int, through endIndex: Int) -> Double {
        guard !cumulativeDistances.isEmpty else { return 0 }
        let start = min(cumulativeDistances.count - 1, max(0, startIndex))
        let end = min(cumulativeDistances.count - 1, max(start, endIndex))
        return cumulativeDistances[end] - cumulativeDistances[start]
    }

    func project(_ location: Coordinate) -> RouteProjection? {
        guard coordinates.count > 1,
              let cell = Self.cell(for: location) else { return nil }
        let candidates = (segmentIndicesByCell[cell] ?? []) + unindexedSegments
        guard !candidates.isEmpty else { return nil }
        return candidates.compactMap { projection(of: location, onto: $0) }
            .min { $0.distanceFromRoute < $1.distanceFromRoute }
    }

    func match(_ location: NavigationLocation, previous: RouteProjection? = nil,
               previousTimestamp: Date? = nil) -> RouteMatch? {
        guard coordinates.count > 1,
              let cell = Self.cell(for: location.coordinate) else { return nil }
        let candidates = (segmentIndicesByCell[cell] ?? []) + unindexedSegments
        guard !candidates.isEmpty else { return nil }
        let accuracy = max(8, location.accuracy)
        let elapsed = previousTimestamp.map { max(0, location.timestamp.timeIntervalSince($0)) } ?? 0
        let expectedProgress = previous.map { $0.alongRoute + max(0, location.speed) * elapsed }
        let maximumDistance = max(250, location.accuracy * 6)
        var bestProjection: RouteProjection?
        var bestScore = Double.infinity

        for index in candidates {
            guard let projection = projection(of: location.coordinate, onto: index),
                  projection.distanceFromRoute <= maximumDistance else { continue }
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let dx = (end.longitude - start.longitude) * 111_320.0 *
                cos(location.coordinate.latitude * .pi / 180)
            let dy = (end.latitude - start.latitude) * 110_574.0
            let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let distanceScore = pow(projection.distanceFromRoute / accuracy, 2)
            var score = distanceScore
            if location.speed >= 1.5, location.course >= 0, location.course <= 360 {
                let difference = abs(location.course - bearing)
                score += pow(min(difference, 360 - difference) / 55, 2)
            }
            if let expectedProgress {
                let continuityScale = max(35, max(0, location.speed) * elapsed + accuracy * 2)
                score += pow((projection.alongRoute - expectedProgress) / continuityScale, 2) * 0.35
            }
            if score < bestScore {
                bestProjection = projection
                bestScore = score
            }
        }
        guard let bestProjection else { return nil }
        return RouteMatch(projection: bestProjection, confidence: exp(-0.5 * min(40, bestScore)))
    }

    private func projection(of location: Coordinate, onto index: Int) -> RouteProjection? {
        guard coordinates.indices.contains(index), segmentLengths.indices.contains(index) else { return nil }
        let start = coordinates[index]
        let end = coordinates[index + 1]
        let metersPerLatitudeDegree = 110_574.0
        let metersPerLongitudeDegree = 111_320.0 * cos(location.latitude * .pi / 180)
        let dx = (end.longitude - start.longitude) * metersPerLongitudeDegree
        let dy = (end.latitude - start.latitude) * metersPerLatitudeDegree
        let px = (location.longitude - start.longitude) * metersPerLongitudeDegree
        let py = (location.latitude - start.latitude) * metersPerLatitudeDegree
        let segmentLengthSquared = dx * dx + dy * dy
        guard segmentLengthSquared > 0 else { return nil }
        let fraction = max(0, min(1, (px * dx + py * dy) / segmentLengthSquared))
        return RouteProjection(
            coordinate: Coordinate(latitude: start.latitude + fraction * (end.latitude - start.latitude),
                                   longitude: start.longitude + fraction * (end.longitude - start.longitude)),
            distanceFromRoute: hypot(px - fraction * dx, py - fraction * dy),
            alongRoute: cumulativeDistances[index] + fraction * segmentLengths[index],
            segment: index)
    }

    private static func cell(for coordinate: Coordinate) -> Cell? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else {
            return nil
        }
        return Cell(latitude: Int(floor(coordinate.latitude / cellSize)),
                    longitude: Int(floor(coordinate.longitude / cellSize)))
    }

    private static func index(segment: Int, from start: Coordinate, to end: Coordinate,
                              in cellSegments: inout [Cell: [Int]]) -> Bool {
        guard start.latitude.isFinite, start.longitude.isFinite,
              end.latitude.isFinite, end.longitude.isFinite,
              (-90...90).contains(start.latitude), (-180...180).contains(start.longitude),
              (-90...90).contains(end.latitude), (-180...180).contains(end.longitude) else { return true }
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let longitudeScale = 111_320.0 * min(abs(cos(startLatitude)), abs(cos(endLatitude)))
        let latitudePadding = indexedProjectionRadius / 110_574.0
        let longitudePadding = indexedProjectionRadius / max(11_132.0, longitudeScale)
        let minimumLatitude = Int(floor((min(start.latitude, end.latitude) - latitudePadding) / cellSize))
        let maximumLatitude = Int(floor((max(start.latitude, end.latitude) + latitudePadding) / cellSize))
        let minimumLongitude = Int(floor((min(start.longitude, end.longitude) - longitudePadding) / cellSize))
        let maximumLongitude = Int(floor((max(start.longitude, end.longitude) + longitudePadding) / cellSize))
        let latitudeCellCount = maximumLatitude - minimumLatitude + 1
        let longitudeCellCount = maximumLongitude - minimumLongitude + 1
        guard latitudeCellCount > 0, longitudeCellCount > 0,
              latitudeCellCount <= 256, longitudeCellCount <= 256,
              latitudeCellCount * longitudeCellCount <= 256 else { return false }
        for latitude in minimumLatitude...maximumLatitude {
            for longitude in minimumLongitude...maximumLongitude {
                cellSegments[Cell(latitude: latitude, longitude: longitude), default: []].append(segment)
            }
        }
        return true
    }
}

struct TransitRouteProgressGeometry {
    private struct ProjectedStop {
        let stopID: String
        let sequence: Int
        let order: Int
        let alongRoute: Double
    }

    private struct LegGeometry {
        let geometry: RouteProgressGeometry
        let stops: [ProjectedStop]

        var length: Double { geometry.length }
    }

    let routeID: UUID
    private let legs: [LegGeometry]
    private let totalLength: Double

    init(route: NavigationRoute) {
        routeID = route.id
        let journeyLegs = route.journey?.legs ?? []
        legs = journeyLegs.map { leg in
            let geometry = RouteProgressGeometry(coordinates: leg.coordinates)
            let orderedStops = leg.transitStops.sorted { $0.sequence < $1.sequence }
            let projectedStops = orderedStops.enumerated().compactMap { order, stop -> ProjectedStop? in
                guard let projection = geometry.project(stop.coordinate),
                      projection.distanceFromRoute <= 250 else { return nil }
                return ProjectedStop(stopID: stop.stopID, sequence: stop.sequence,
                                     order: order, alongRoute: projection.alongRoute)
            }
            return LegGeometry(geometry: geometry, stops: projectedStops)
        }
        totalLength = legs.reduce(0) { $0 + $1.length }
    }

    func progress(route: NavigationRoute, at coordinate: Coordinate,
                  accuracy: Double, previousLegIndex: Int? = nil) -> TransitNavigationProgress? {
        guard route.id == routeID, let journey = route.journey,
              journey.legs.count == legs.count, totalLength > 0 else { return nil }

        let matches = legs.indices.compactMap { index -> (Int, RouteProjection, Double)? in
            let leg = journey.legs[index]
            guard legs[index].length > 0 else { return nil }
            let projection: RouteProjection?
            if accuracy * 2 > 500 {
                projection = MapMatcher.project(coordinate, onto: leg.coordinates)
            } else {
                projection = legs[index].geometry.project(coordinate)
                    ?? MapMatcher.project(coordinate, onto: leg.coordinates)
            }
            guard let projection else { return nil }
            return (index, projection, legs[index].length)
        }
        guard let nearest = matches.min(by: {
            $0.1.distanceFromRoute < $1.1.distanceFromRoute
        }) else { return nil }
        let maximumMatchDistance = max(150, accuracy * 2)
        let previousMatch = previousLegIndex.flatMap { index in matches.first(where: { $0.0 == index }) }
        let match = previousMatch.map {
            $0.1.distanceFromRoute <= maximumMatchDistance &&
                $0.1.distanceFromRoute <= nearest.1.distanceFromRoute + 35
                ? $0 : nearest
        } ?? nearest
        guard match.1.distanceFromRoute <= maximumMatchDistance else { return nil }

        let distanceBeforeLeg = legs.prefix(match.0).reduce(0) { $0 + $1.length }
        let legDistance = min(match.2, max(0, match.1.alongRoute))
        let routeFraction = min(1, max(0, (distanceBeforeLeg + legDistance) / totalLength))
        let leg = journey.legs[match.0]
        let stopPositions = legs[match.0].stops
        let upcomingStops = stopPositions.filter {
            $0.order > 0 && $0.alongRoute >= legDistance - 60
        }
        let nextPosition = upcomingStops.first
        let nextStop = nextPosition.flatMap { position in
            leg.transitStops.first {
                $0.stopID == position.stopID && $0.sequence == position.sequence
            }
        }

        return TransitNavigationProgress(
            legIndex: match.0,
            legFraction: min(1, max(0, legDistance / match.2)),
            routeFraction: routeFraction,
            legDistance: legDistance,
            distanceToLegEnd: max(0, match.2 - legDistance),
            distanceFromRoute: match.1.distanceFromRoute,
            nextStop: nextStop,
            distanceToNextStop: nextStop.map { coordinate.distance(to: $0.coordinate) },
            stopsUntilAlighting: leg.mode.uppercased() == "WALK" ? nil : upcomingStops.count)
    }
}

enum TransitRouteProgressCalculator {
    static func progress(route: NavigationRoute, at coordinate: Coordinate,
                         accuracy: Double, previousLegIndex: Int? = nil) -> TransitNavigationProgress? {
        TransitRouteProgressGeometry(route: route).progress(
            route: route, at: coordinate, accuracy: accuracy, previousLegIndex: previousLegIndex)
    }

    static func progress(route: NavigationRoute, geometry: TransitRouteProgressGeometry,
                         at coordinate: Coordinate, accuracy: Double,
                         previousLegIndex: Int? = nil) -> TransitNavigationProgress? {
        geometry.progress(route: route, at: coordinate, accuracy: accuracy,
                          previousLegIndex: previousLegIndex)
    }
}
