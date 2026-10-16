#if os(iOS)
import Foundation
import CoreGraphics

nonisolated struct DetailedRoadGraphic: Sendable {
    enum Kind: String, Sendable { case casing, surface, junction, gore, edge, separator, center, sharedBoundary, arrow }
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
    var opacity: Double = 1
    var interiorRings: [[DetailedRoad.Point]] = []
}

/// Ground geometry is independent of the data provider and map theme.
nonisolated enum DetailedRoadGeometry {
    enum GeometryError: Error { case tooComplex }
    struct Vector: Sendable {
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
    struct Sample: Sendable {
        let point: Vector
        let fraction: Double
    }

    static func build(_ roads: [NormalizedDetailedRoad], in query: DetailedRoadQuery) throws -> [DetailedRoadGraphic] {
        var graphics: [DetailedRoadGraphic] = []
        var annotations: [DetailedRoadGraphic] = []
        var vertices = 0
        var annotationVertices = 0
        struct Plane: Hashable {
            let level: Int
            let bridge: Bool
            let renderLevel: String
        }
        struct Cell: Hashable {
            let plane: Plane
            let x: Int
            let y: Int
        }
        var asphalt: [Plane: CGMutablePath] = [:]
        var planeRoads: [Plane: NormalizedDetailedRoad] = [:]
        var pieces: [Plane: [CGPath]] = [:]
        var bins: [Cell: [Int]] = [:]
        func plane(_ road: NormalizedDetailedRoad) -> Plane {
            Plane(level: road.layer, bridge: road.bridge, renderLevel: road.renderLevel.rawValue)
        }
        func addAsphalt(_ path: CGPath, road: NormalizedDetailedRoad) {
            let key = plane(road)
            if asphalt[key] == nil { asphalt[key] = CGMutablePath(); planeRoads[key] = road }
            asphalt[key]?.addPath(path)
            let index = pieces[key, default: []].count
            pieces[key, default: []].append(path)
            let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
            guard !box.isNull, !box.isEmpty else { return }
            for x in Int(floor(box.minX / 64))...Int(floor(box.maxX / 64)) {
                for y in Int(floor(box.minY / 64))...Int(floor(box.maxY / 64)) {
                    bins[Cell(plane: key, x: x, y: y), default: []].append(index)
                }
            }
        }
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
        func append(_ kind: DetailedRoadGraphic.Kind, _ vectors: [Vector], road: NormalizedDetailedRoad,
                    polygon: Bool = false, lane: NormalizedDetailedRoad.Lane? = nil,
                    bearing: Double = 0, arrowScale: Double = 1, opacity: Double = 1) throws {
            guard vectors.count >= (polygon ? 4 : (kind == .arrow ? 1 : 2)) else { return }
            if kind == .casing { return } // The casing follows the final union, never internal segment caps.
            if kind == .surface {
                addAsphalt(DetailedRoadSurfaceGeometry.path(vectors), road: road)
                return
            }
            let decoration = !polygon || kind == .junction || kind == .gore
            if decoration {
                // Reserve the budget for continuous asphalt before admitting optional detail.
                guard annotationVertices + vectors.count <= 100_000, annotations.count < 10_000 else { return }
                annotationVertices += vectors.count
            } else {
                vertices += vectors.count
                guard vertices <= 250_000, graphics.count < 12_000 else { throw GeometryError.tooComplex }
            }
            let graphic = DetailedRoadGraphic(kind: kind, level: road.layer,
                points: vectors.map(coordinate), polygon: polygon, roadClass: road.roadClass,
                renderLevel: road.renderLevel, bridge: road.bridge, covered: road.covered,
                confidence: road.confidence, directionality: road.directionality,
                laneType: lane?.direction == .bothWays ? "shared" : (lane?.direction == .unknown ? "unknown" : "driving"),
                direction: lane?.direction ?? .unknown, turnTypes: lane?.turns ?? [],
                bearing: bearing, arrowScale: arrowScale, opacity: opacity)
            if decoration { annotations.append(graphic) } else { graphics.append(graphic) }
        }
        let network = try DetailedRoadTopology.build(roads, project: project)
        for junction in network.junctions {
            guard junction.surface.contains(where: { $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY }) else { continue }
            try append(.casing, junction.casing, road: junction.road, polygon: true)
            // Same asphalt for the approaches and centre: no overlapping translucent patches.
            try append(.surface, junction.surface, road: junction.road, polygon: true)
            if !junction.continuation {
                try append(.junction, junction.surface, road: junction.road, polygon: true)
            }
            try append(.gore, junction.gore, road: junction.road, polygon: true)
            for edge in junction.edgeLines { try append(.edge, edge, road: junction.road, opacity: 0.65) }
            for marking in junction.separators {
                try append(marking.kind, marking.points, road: junction.road, opacity: marking.opacity)
            }
        }
        for corridor in network.corridors {
            try Task.checkCancellation()
            let road = corridor.road
            let samples = trimmed(corridor.line, start: corridor.startInset, end: corridor.endInset)
            guard samples.count > 1 else { continue }
            var sections: [[Sample]] = [], section: [Sample] = []
            for index in 1..<samples.count {
                let a = samples[index - 1], b = samples[index]
                let size = (b.point - a.point).length
                guard size >= 0.15,
                      let (from, to) = clipped(a, b, minX: minX, maxX: maxX, minY: minY, maxY: maxY) else {
                    if section.count > 1 { sections.append(section) }; section = []; continue
                }
                if let previous = section.last, (previous.point - from.point).length > 0.01 {
                    if section.count > 1 { sections.append(section) }; section = []
                }
                if section.isEmpty { section.append(from) }
                section.append(to)
            }
            if section.count > 1 { sections.append(section) }
            for line in sections {
                // The surface is a union of section envelopes. A sharp offset can no longer delete a road.
                addAsphalt(DetailedRoadSurfaceGeometry.corridor(line, road: road), road: road)
                let safePaint = !selfIntersects(line.map(\.point), closed: false)
                func emit(_ kind: DetailedRoadGraphic.Kind, _ vectors: [Vector], polygon: Bool = false,
                          lane: NormalizedDetailedRoad.Lane? = nil, bearing: Double = 0,
                          arrowScale: Double = 1, opacity: Double = 1) throws {
                    try append(kind, vectors, road: road, polygon: polygon, lane: lane,
                               bearing: bearing, arrowScale: arrowScale, opacity: opacity)
                }
                guard road.marked, road.confidence != .estimated, safePaint else { continue }
                let length = pathLength(line.map(\.point))
                let beginsAtPort = abs(line.first!.fraction - samples.first!.fraction) < 0.000001
                let endsAtPort = abs(line.last!.fraction - samples.last!.fraction) < 0.000001
                let freeInset = min(6, length * 0.15)
                let startClearance = beginsAtPort ? corridor.startPaintClearance : 0
                let endClearance = endsAtPort ? corridor.endPaintClearance : 0
                let paint = trimmed(line,
                    start: max(startClearance, beginsAtPort && corridor.startInset == 0 ? freeInset : 0),
                    end: max(endClearance, endsAtPort && corridor.endInset == 0 ? freeInset : 0))
                guard paint.count > 1 else { continue }
                let startFade = beginsAtPort ? corridor.startFade : 0
                let endFade = endsAtPort ? corridor.endFade : 0
                for band in paintBands(paint, startFade: startFade, endFade: endFade) {
                    let edges = [offset(band.line, by: { road.centerOffset(at: $0) + road.width(at: $0) / 2 - 0.2 }),
                                 offset(band.line, by: { road.centerOffset(at: $0) - road.width(at: $0) / 2 + 0.2 })]
                    for edge in edges where !selfIntersects(edge, closed: false) { try emit(.edge, edge, opacity: band.opacity) }
                    if road.lanes.count >= 2 {
                        for index in 1..<road.lanes.count {
                            let a = road.lanes[index - 1], b = road.lanes[index]
                            let kind: DetailedRoadGraphic.Kind = a.direction == .bothWays || b.direction == .bothWays ? .sharedBoundary
                                : (a.direction != b.direction && a.direction != .unknown && b.direction != .unknown ? .center : .separator)
                            let separator = offset(band.line, by: { road.boundaryOffset(after: index, at: $0) })
                            guard !selfIntersects(separator, closed: false) else { continue }
                            try emit(kind, separator, lane: b, opacity: band.opacity)
                        }
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
                        guard length >= 35,
                              reversed ? (beginsAtPort && corridor.line.first!.fraction == 0)
                                  : (endsAtPort && corridor.line.last!.fraction == 1) else { continue }
                        let oriented = reversed ? Array(line.reversed()) : line
                        let clearance = max(15, (reversed ? startFade : endFade) + 8)
                        let distance = length - max(clearance, min(30, length * 0.35))
                        guard distance >= (reversed ? endClearance : startClearance),
                              length - distance >= (reversed ? startClearance : endClearance),
                              let (anchor, heading) = arrowAnchor(oriented, distance: distance),
                              lane.width(at: anchor.fraction) >= 2 else { continue }
                        let point = anchor.point + heading.left * ((reversed ? -1 : 1) * road.laneCenter(index, at: anchor.fraction))
                        let bearing = atan2(heading.x, heading.y) * 180 / .pi
                        try emit(.arrow, [point], lane: lane, bearing: bearing,
                                 arrowScale: min(1.2, lane.width(at: anchor.fraction) / 3.1))
                    }
                }
            }
        }
        var normalizedAsphalt: [Plane: CGPath] = [:]
        var gradeMasks: [Plane: CGMutablePath] = [:]
        for junction in network.junctions where !junction.gradeRoads.isEmpty {
            let patch = DetailedRoadSurfaceGeometry.path(junction.surface)
            let zone = CGPath(rect: patch.boundingBoxOfPath.insetBy(dx: -2, dy: -2), transform: nil)
            let keys = Set(junction.gradeRoads.map(plane))
            for key in keys {
                let mask = gradeMasks[key] ?? CGMutablePath()
                for other in keys where other != key {
                    if let path = asphalt[other] { mask.addPath(path.intersection(zone)) }
                }
                gradeMasks[key] = mask
            }
        }
        for key in asphalt.keys.sorted(by: { a, b in
            if a.level != b.level { return a.level < b.level }
            return a.renderLevel < b.renderLevel
        }) {
            try Task.checkCancellation()
            guard let path = asphalt[key], let road = planeRoads[key] else { continue }
            let surface = path.normalized(using: .winding)
            normalizedAsphalt[key] = surface
            var border = surface.copy(strokingWithWidth: 0.65, lineCap: .round, lineJoin: .round, miterLimit: 1)
            if let mask = gradeMasks[key] { border = border.subtracting(mask) }
            let casing = surface.union(border)
            for (kind, path) in [(DetailedRoadGraphic.Kind.casing, casing), (.surface, surface)] {
                for polygon in DetailedRoadSurfaceGeometry.polygons(path) {
                    let count = polygon.outer.count + polygon.holes.reduce(0) { $0 + $1.count }
                    vertices += count
                    guard vertices <= 350_000, graphics.count < 12_000 else { throw GeometryError.tooComplex }
                    graphics.append(DetailedRoadGraphic(kind: kind, level: road.layer,
                        points: polygon.outer.map(coordinate), polygon: true, roadClass: road.roadClass,
                        renderLevel: road.renderLevel, bridge: road.bridge, covered: road.covered,
                        confidence: road.confidence, directionality: road.directionality,
                        laneType: "unknown", direction: .unknown, turnTypes: [], bearing: 0, arrowScale: 1,
                        interiorRings: polygon.holes.map { $0.map(coordinate) }))
                }
            }
        }
        var localMasks: [Cell: (surface: CGPath, edge: CGPath)] = [:]
        for annotation in annotations {
            let key = Plane(level: annotation.level, bridge: annotation.bridge, renderLevel: annotation.renderLevel.rawValue)
            guard normalizedAsphalt[key] != nil else { continue }
            var output = [annotation]
            if !annotation.polygon && annotation.kind != .arrow {
                let line = DetailedRoadSurfaceGeometry.path(annotation.points.map(project), closed: false)
                let box = line.boundingBoxOfPath
                output = []
                for x in Int(floor(box.minX / 64))...Int(floor(box.maxX / 64)) {
                    for y in Int(floor(box.minY / 64))...Int(floor(box.maxY / 64)) {
                        try Task.checkCancellation()
                        let cell = Cell(plane: key, x: x, y: y)
                        guard let indices = bins[cell], !indices.isEmpty else { continue }
                        let rect = CGRect(x: Double(x) * 64, y: Double(y) * 64, width: 64, height: 64)
                        let fragment = line.lineIntersection(CGPath(rect: rect, transform: nil))
                        guard !fragment.isEmpty else { continue }
                        let masks: (surface: CGPath, edge: CGPath)
                        if let cached = localMasks[cell] { masks = cached }
                        else {
                            let local = CGMutablePath()
                            for index in indices { if let path = pieces[key]?[index] { local.addPath(path) } }
                            let surface = local.intersection(CGPath(rect: rect.insetBy(dx: -2, dy: -2), transform: nil))
                            masks = (surface, surface.copy(strokingWithWidth: 1.1, lineCap: .round, lineJoin: .round, miterLimit: 1))
                            localMasks[cell] = masks
                        }
                        let mask = annotation.kind == .edge ? masks.edge : masks.surface
                        for points in DetailedRoadSurfaceGeometry.lines(fragment.lineIntersection(mask)) {
                            output.append(DetailedRoadGraphic(kind: annotation.kind, level: annotation.level,
                                points: points.map(coordinate), polygon: false, roadClass: annotation.roadClass,
                                renderLevel: annotation.renderLevel, bridge: annotation.bridge, covered: annotation.covered,
                                confidence: annotation.confidence, directionality: annotation.directionality,
                                laneType: annotation.laneType, direction: annotation.direction, turnTypes: [],
                                bearing: 0, arrowScale: 1, opacity: annotation.opacity))
                        }
                    }
                }
            }
            for graphic in output {
                guard vertices + graphic.points.count <= 350_000, graphics.count < 16_000 else { continue }
                vertices += graphic.points.count
                graphics.append(graphic)
            }
        }
        return graphics
    }

    /// Clip long OSM ways before buffering, keeping interpolation in the original width profile.
    private static func clipped(_ a: Sample, _ b: Sample, minX: Double, maxX: Double,
                                minY: Double, maxY: Double) -> (Sample, Sample)? {
        let delta = b.point - a.point
        var from = 0.0, to = 1.0
        for (p, q) in [(-delta.x, a.point.x - minX), (delta.x, maxX - a.point.x),
                       (-delta.y, a.point.y - minY), (delta.y, maxY - a.point.y)] {
            if abs(p) < 0.0000001 { if q < 0 { return nil }; continue }
            let t = q / p
            if p < 0 { from = max(from, t) } else { to = min(to, t) }
            if from > to { return nil }
        }
        guard to - from > 0.000001 else { return nil }
        return (Sample(point: a.point + delta * from, fraction: a.fraction + (b.fraction - a.fraction) * from),
                Sample(point: a.point + delta * to, fraction: a.fraction + (b.fraction - a.fraction) * to))
    }

    static func pathLength(_ points: [Vector]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
    }
    private static func paintBands(_ line: [Sample], startFade: Double, endFade: Double) -> [(line: [Sample], opacity: Double)] {
        let length = pathLength(line.map(\.point))
        guard startFade > 0 || endFade > 0 else { return [(line, 1)] }
        var stops = [0.0, length]
        for index in 1...4 {
            if startFade > 0 { stops.append(min(length, startFade * Double(index) / 4)) }
            if endFade > 0 { stops.append(max(0, length - endFade * Double(index) / 4)) }
        }
        stops = Array(Set(stops)).sorted()
        return zip(stops, stops.dropFirst()).compactMap { from, to in
            guard to - from > 0.05 else { return nil }
            let middle = (from + to) / 2
            let alpha = min(startFade > 0 ? min(1, middle / startFade) : 1,
                            endFade > 0 ? min(1, (length - middle) / endFade) : 1)
            return (trimmed(line, start: from, end: length - to), alpha * alpha * (3 - 2 * alpha))
        }
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
    static func selfIntersects(_ input: [Vector], closed: Bool) -> Bool {
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
    static func trimmed(_ samples: [Sample], start: Double, end: Double) -> [Sample] {
        let length = pathLength(samples.map(\.point))
        guard length > start + end else { return [] }
        var result: [Sample] = [], traveled = 0.0
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index], size = (b.point - a.point).length
            let next = traveled + size
            if next > start && traveled < length - end {
                let from = max(0, start - traveled) / size, to = min(size, length - end - traveled) / size
                if result.isEmpty { result.append(Sample(point: a.point + (b.point - a.point) * from,
                    fraction: a.fraction + (b.fraction - a.fraction) * from)) }
                result.append(Sample(point: a.point + (b.point - a.point) * to,
                    fraction: a.fraction + (b.fraction - a.fraction) * to))
            }
            traveled = next
        }
        return result
    }
    static func arrowAnchor(_ samples: [Sample], distance: Double) -> (Sample, Vector)? {
        var traveled = 0.0
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index], size = (b.point - a.point).length
            if traveled + size > distance + 0.000001 || (index == samples.count - 1 && traveled + size >= distance) {
                let fraction = max(0, min(1, (distance - traveled) / size))
                return (Sample(point: a.point + (b.point - a.point) * fraction,
                               fraction: a.fraction + (b.fraction - a.fraction) * fraction), (b.point - a.point).unit)
            }
            traveled += size
        }
        return nil
    }
}
#endif
