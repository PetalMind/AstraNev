#if os(iOS)
import Foundation

nonisolated struct DetailedRoadGraphic: Sendable {
    enum Kind: String, Sendable { case casing, surface, edge, separator, center, sharedBoundary, arrow }
    let kind: Kind
    let level: Int
    let points: [DetailedRoad.Point]
    let polygon: Bool
    let roadClass: String
    let renderLevel: RoadRenderLevel
    let bridge: Bool
    let covered: Bool
    let confidence: RoadGeometryConfidence
    let directionality: RoadDirectionality
    let laneType: String
    let direction: RoadLaneDirection
    let turnTypes: [String]
    let bearing: Double
    let arrowScale: Double
}

/// Ground geometry is independent of the data provider and map theme.
nonisolated enum DetailedRoadGeometry {
    enum GeometryError: Error { case tooComplex }
    private struct Vector {
        var x: Double
        var y: Double
        static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Self, b: Double) -> Self { Self(x: a.x * b, y: a.y * b) }
        var length: Double { hypot(x, y) }
        var unit: Self { self * (1 / max(0.001, length)) }
        var left: Self { Self(x: -y, y: x) }
        func dot(_ b: Self) -> Double { x * b.x + y * b.y }
        func cross(_ b: Self) -> Double { x * b.y - y * b.x }
    }
    private struct Sample {
        let point: Vector
        let fraction: Double
    }

    static func build(_ roads: [NormalizedDetailedRoad], in query: DetailedRoadQuery) throws -> [DetailedRoadGraphic] {
        var graphics: [DetailedRoadGraphic] = []
        var vertices = 0
        var seen: Set<Int64> = []
        let latitude = (query.south + query.north) / 2
        let cosine = cos(latitude * .pi / 180)
        let originLongitude = (query.west + query.east) / 2
        let meters = 6_371_008.8 * .pi / 180
        func project(_ p: DetailedRoad.Point) -> Vector {
            Vector(x: (p.longitude - originLongitude) * meters * cosine, y: (p.latitude - latitude) * meters)
        }
        func coordinate(_ p: Vector) -> DetailedRoad.Point {
            DetailedRoad.Point(latitude: latitude + p.y / meters, longitude: originLongitude + p.x / (meters * cosine))
        }
        let minX = (query.west - originLongitude) * meters * cosine - 80
        let maxX = (query.east - originLongitude) * meters * cosine + 80
        let minY = (query.south - latitude) * meters - 80
        let maxY = (query.north - latitude) * meters + 80
        for road in roads where seen.insert(road.id).inserted {
            try Task.checkCancellation()
            guard road.confidence != .invalid, road.renderLevel != .underground else { continue }
            let points = road.points.map(project)
            let samples = sampled(points)
            guard let last = samples.last, last.fraction == 1 else { continue }
            var sections: [[Sample]] = [], section: [Sample] = []
            for index in 1..<samples.count {
                let a = samples[index - 1], b = samples[index]
                let intersects = max(a.point.x, b.point.x) >= minX && min(a.point.x, b.point.x) <= maxX
                    && max(a.point.y, b.point.y) >= minY && min(a.point.y, b.point.y) <= maxY
                if !intersects || (b.point - a.point).length < 0.15 || (b.point - a.point).length > 10_000 {
                    if section.count > 1 { sections.append(section) }; section = []; continue
                }
                if section.isEmpty { section.append(a) }
                section.append(b)
            }
            if section.count > 1 { sections.append(section) }
            for line in sections {
                // Reject geometry with loops before any lane annotations are emitted.
                guard !selfIntersects(line.map(\.point), closed: false) else { continue }
                let casingLeft = offset(line, by: { road.centerOffset(at: $0) + road.width(at: $0) / 2 + 0.325 })
                let casingRight = offset(line, by: { road.centerOffset(at: $0) - road.width(at: $0) / 2 - 0.325 })
                let left = offset(line, by: { road.centerOffset(at: $0) + road.width(at: $0) / 2 })
                let right = offset(line, by: { road.centerOffset(at: $0) - road.width(at: $0) / 2 })
                let outer = ring(left: casingLeft, right: casingRight), inner = ring(left: left, right: right)
                guard !selfIntersects(outer, closed: true), !selfIntersects(inner, closed: true) else { continue }
                func emit(_ kind: DetailedRoadGraphic.Kind, _ vectors: [Vector], polygon: Bool = false,
                          lane: NormalizedDetailedRoad.Lane? = nil, bearing: Double = 0, arrowScale: Double = 1) throws {
                    guard vectors.count >= (polygon ? 4 : (kind == .arrow ? 1 : 2)) else { return }
                    vertices += vectors.count
                    guard vertices <= 250_000, graphics.count < 12_000 else { throw GeometryError.tooComplex }
                    graphics.append(DetailedRoadGraphic(kind: kind, level: road.layer,
                        points: vectors.map(coordinate), polygon: polygon, roadClass: road.roadClass,
                        renderLevel: road.renderLevel, bridge: road.bridge, covered: road.covered,
                        confidence: road.confidence, directionality: road.directionality,
                        laneType: lane?.direction == .bothWays ? "shared" : (lane?.direction == .unknown ? "unknown" : "driving"),
                        direction: lane?.direction ?? .unknown, turnTypes: lane?.turns ?? [],
                        bearing: bearing, arrowScale: arrowScale))
                }
                try emit(.casing, outer, polygon: true)
                try emit(.surface, inner, polygon: true)
                guard road.marked, road.confidence != .estimated else { continue }
                let length = pathLength(line.map(\.point))
                let inset = road.roadClass.hasSuffix("_link") ? 8.0 : 6.0
                let paint = trimmed(line, inset: min(inset, length * 0.15))
                guard paint.count > 1 else { continue }
                let edges = [offset(paint, by: { road.centerOffset(at: $0) + road.width(at: $0) / 2 - 0.2 }),
                             offset(paint, by: { road.centerOffset(at: $0) - road.width(at: $0) / 2 + 0.2 })]
                for edge in edges where !selfIntersects(edge, closed: false) { try emit(.edge, edge) }
                if road.lanes.count >= 2 {
                    for index in 1..<road.lanes.count {
                        let a = road.lanes[index - 1], b = road.lanes[index]
                        let kind: DetailedRoadGraphic.Kind = a.direction == .bothWays || b.direction == .bothWays ? .sharedBoundary
                            : (a.direction != b.direction && a.direction != .unknown && b.direction != .unknown ? .center : .separator)
                        let separator = offset(paint, by: { road.boundaryOffset(after: index, at: $0) })
                        guard !selfIntersects(separator, closed: false) else { continue }
                        try emit(kind, separator, lane: b)
                    }
                }
                guard road.confidence == .exact else { continue }
                for index in road.lanes.indices {
                    let lane = road.lanes[index]
                    guard !lane.turns.isEmpty else { continue }
                    let directions: [Bool]
                    switch lane.direction {
                    case .forward: directions = [false]
                    case .backward: directions = [true]
                    case .bothWays: directions = [false, true]
                    case .unknown: continue
                    }
                    for reversed in directions {
                        guard reversed ? line.first!.fraction == 0 : line.last!.fraction == 1, length >= 35 else { continue }
                        let oriented = reversed ? Array(line.reversed()) : line
                        guard let (anchor, heading) = arrowAnchor(oriented, distance: length - min(30, length * 0.35)),
                              lane.width(at: anchor.fraction) >= 2 else { continue }
                        let point = anchor.point + heading.left * ((reversed ? -1 : 1) * road.laneCenter(index, at: anchor.fraction))
                        let bearing = atan2(heading.x, heading.y) * 180 / .pi
                        try emit(.arrow, [point], lane: lane, bearing: bearing,
                                 arrowScale: min(1.2, lane.width(at: anchor.fraction) / 3.1))
                    }
                }
            }
        }
        return graphics
    }

    private static func pathLength(_ points: [Vector]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }
    private static func sampled(_ points: [Vector]) -> [Sample] {
        let length = pathLength(points)
        guard length > 0 else { return [] }
        var result: [Sample] = [], traveled = 0.0
        for index in points.indices {
            if index > 0 { traveled += (points[index] - points[index - 1]).length }
            if let previous = result.last, (points[index] - previous.point).length < 0.15 { continue }
            result.append(Sample(point: points[index], fraction: index == points.count - 1 ? 1 : traveled / length))
        }
        return result
    }
    private static func ring(left: [Vector], right: [Vector]) -> [Vector] {
        guard let start = left.first else { return [] }
        return left + right.reversed() + [start]
    }

    private static func offset(_ samples: [Sample], by distance: (Double) -> Double) -> [Vector] {
        var result: [Vector] = []
        let miterLimit = 2.5
        for index in samples.indices {
            let point = samples[index].point, width = distance(samples[index].fraction)
            if index == 0 {
                result.append(point + (samples[1].point - point).unit.left * width); continue
            }
            if index == samples.count - 1 {
                result.append(point + (point - samples[index - 1].point).unit.left * width); continue
            }
            let before = (point - samples[index - 1].point).unit.left
            let after = (samples[index + 1].point - point).unit.left
            let bisector = (before + after).unit
            let denominator = bisector.dot(after)
            let miter = denominator > 0.001 ? abs(width / denominator) : .infinity
            let adjacent = min((point - samples[index - 1].point).length, (samples[index + 1].point - point).length)
            if denominator > 0.15, miter <= max(0.01, abs(width)) * miterLimit, miter <= adjacent * 0.75 {
                result.append(point + bisector * (width / denominator))
            } else {
                // An actual bevel uses both adjacent normals instead of moving a single corner point.
                result.append(point + before * width)
                result.append(point + after * width)
            }
        }
        return result
    }

    /// Spatial buckets keep intersection checks bounded without a quadratic all-segment scan.
    private static func selfIntersects(_ input: [Vector], closed: Bool) -> Bool {
        var points: [Vector] = []
        for point in input {
            if let last = points.last, (last - point).length < 0.01 { continue }
            points.append(point)
        }
        if closed, points.count > 1, (points.first! - points.last!).length < 0.01 { points.removeLast() }
        guard points.count >= (closed ? 3 : 2) else { return true }
        let count = closed ? points.count : points.count - 1
        struct Cell: Hashable { let x: Int; let y: Int }
        var buckets: [Cell: [Int]] = [:]
        var work = 0
        for index in 0..<count {
            if Task.isCancelled { return true }
            let a = points[index], b = points[(index + 1) % points.count]
            let minX = Int(floor(min(a.x, b.x) / 32)), maxX = Int(floor(max(a.x, b.x) / 32))
            let minY = Int(floor(min(a.y, b.y) / 32)), maxY = Int(floor(max(a.y, b.y) / 32))
            guard (maxX - minX + 1) * (maxY - minY + 1) <= 4_096 else { return true }
            var checked: Set<Int> = []
            for x in minX...maxX { for y in minY...maxY {
                let cell = Cell(x: x, y: y)
                for previous in buckets[cell] ?? [] where checked.insert(previous).inserted {
                    if abs(previous - index) <= 1 || (closed && previous == 0 && index == count - 1) { continue }
                    work += 1
                    guard work < 50_000 else { return true }
                    let c = points[previous], d = points[(previous + 1) % points.count]
                    if intersects(a, b, c, d) { return true }
                }
                buckets[cell, default: []].append(index)
            } }
        }
        return false
    }
    private static func intersects(_ a: Vector, _ b: Vector, _ c: Vector, _ d: Vector) -> Bool {
        let ab = b - a, cd = d - c
        let denominator = ab.cross(cd)
        if abs(denominator) < 0.000001 {
            guard abs((c - a).cross(ab)) < 0.001 else { return false }
            return max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x)) + 0.001
                && max(min(a.y, b.y), min(c.y, d.y)) <= min(max(a.y, b.y), max(c.y, d.y)) + 0.001
        }
        let t = (c - a).cross(cd) / denominator, u = (c - a).cross(ab) / denominator
        return t >= -0.00001 && t <= 1.00001 && u >= -0.00001 && u <= 1.00001
    }
    private static func trimmed(_ samples: [Sample], inset: Double) -> [Sample] {
        let length = pathLength(samples.map(\.point))
        guard length > inset * 2 else { return [] }
        var result: [Sample] = [], traveled = 0.0
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index], size = (b.point - a.point).length
            let next = traveled + size
            if next > inset && traveled < length - inset {
                let from = max(0, inset - traveled) / size, to = min(size, length - inset - traveled) / size
                if result.isEmpty { result.append(Sample(point: a.point + (b.point - a.point) * from,
                    fraction: a.fraction + (b.fraction - a.fraction) * from)) }
                result.append(Sample(point: a.point + (b.point - a.point) * to,
                    fraction: a.fraction + (b.fraction - a.fraction) * to))
            }
            traveled = next
        }
        return result
    }
    private static func arrowAnchor(_ samples: [Sample], distance: Double) -> (Sample, Vector)? {
        var traveled = 0.0
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index], size = (b.point - a.point).length
            if traveled + size >= distance {
                let fraction = (distance - traveled) / size
                return (Sample(point: a.point + (b.point - a.point) * fraction,
                               fraction: a.fraction + (b.fraction - a.fraction) * fraction), (b.point - a.point).unit)
            }
            traveled += size
        }
        return nil
    }
}
#endif
