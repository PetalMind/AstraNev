#if os(iOS)
import CoreGraphics
import Foundation

/// Presentation geometry only. Provider paths remain the authority for access and routing.
nonisolated enum MapSurfaceNetworkGeometry {
    typealias Point = DetailedRoad.Point
    typealias Vector = DetailedRoadGeometry.Vector
    struct Plane: Hashable, Sendable {
        let layer: Int
        let level: Int
        let bridge: Bool
    }
    struct Surface: Sendable {
        let rings: [[Point]]
        let plane: Plane
        let kind: String
        let paved: Bool?
        let width: Double // Cartographic width for a centreline, never a surveyed measurement.
    }
    struct Crossing: Sendable {
        let point: Point
        let rotation: Double
    }
    struct Input: Sendable {
        let latitude: Double
        let longitude: Double
        let paths: [Surface]
        let areas: [Surface]
        let roads: [Surface]
        let crossings: [Crossing]
    }
    struct Graphic: Sendable {
        let rings: [[Point]]
        let plane: Plane
        let part: String
        let kind: String
        let paved: Bool?
    }
    struct Output: Sendable {
        var graphics: [Graphic] = []
        var resolvedCrossings: [Int] = []
    }
    private struct Material: Hashable { let plane: Plane; let kind: String; let paved: Bool? }
    private struct Patch: Hashable { let material: Material; let component: Int }
    private struct Region: Hashable { let plane: Plane; let component: Int }
    private struct Vertex: Hashable { let plane: Plane; let x: Int; let y: Int }
    private struct Cell: Hashable { let plane: Plane; let x: Int; let y: Int }
    private struct End {
        let line: Int
        let start: Bool
        let point: Vector
        let outward: Vector
        let material: Material
    }
    enum GeometryError: Error { case budget }

    static func build(_ input: Input) throws -> Output {
        let scale = 111_320.0
        let longitudeScale = scale * max(0.1, cos(input.latitude * .pi / 180))
        func project(_ point: Point) -> Vector {
            var longitude = point.longitude - input.longitude
            longitude -= (longitude / 360).rounded() * 360
            return Vector(x: longitude * longitudeScale, y: (point.latitude - input.latitude) * scale)
        }
        func coordinate(_ point: Vector) -> Point {
            let longitude = input.longitude + point.x / longitudeScale
            return Point(latitude: input.latitude + point.y / scale,
                longitude: longitude - floor((longitude + 180) / 360) * 360)
        }
        func polygon(_ surface: Surface) -> CGPath {
            guard let outer = surface.rings.first else { return CGMutablePath() }
            var path = DetailedRoadSurfaceGeometry.path(outer.map(project))
            for hole in surface.rings.dropFirst() {
                path = path.subtracting(DetailedRoadSurfaceGeometry.path(hole.map(project)))
            }
            return path
        }
        var output = Output(), vertices = 0
        func emit(_ path: CGPath, plane: Plane, part: String, kind: String = "footway", paved: Bool? = nil) throws {
            for polygon in DetailedRoadSurfaceGeometry.polygons(path) {
                let rings = [polygon.outer] + polygon.holes
                vertices += rings.reduce(0) { $0 + $1.count }
                guard vertices <= 80_000, output.graphics.count < 4_000 else { throw GeometryError.budget }
                output.graphics.append(Graphic(rings: rings.map { $0.map(coordinate) }, plane: plane,
                    part: part, kind: kind, paved: paved))
            }
        }
        var roadMasks: [Plane: CGPath] = [:]
        for road in input.roads {
            try Task.checkCancellation()
            let path = polygon(road)
            roadMasks[road.plane] = roadMasks[road.plane].map { $0.union(path) } ?? path
        }
        var lines = input.paths.map { ($0.rings.first ?? []).map(project) }
        var parents = Array(0..<(input.paths.count + input.areas.count))
        func root(_ value: Int) -> Int {
            var current = value
            while parents[current] != current { current = parents[current] }
            return current
        }
        func connect(_ a: Int, _ b: Int) {
            let first = root(a), second = root(b)
            if first != second { parents[max(first, second)] = min(first, second) }
        }
        // A coincident source vertex is evidence of connectivity. Buffer overlap alone
        // must not merge parallel paths that happen to use wide cartographic ribbons.
        var verticesAt: [Vertex: Int] = [:]
        for (index, surface) in (input.paths + input.areas).enumerated() {
            for ring in surface.rings { for point in ring.map(project) {
                let key = Vertex(plane: surface.plane, x: Int((point.x * 100).rounded()), y: Int((point.y * 100).rounded()))
                if let peer = verticesAt[key] { connect(index, peer) } else { verticesAt[key] = index }
            } }
        }
        // Repair only mutual, nearly collinear dangling ends of the same material and plane.
        // A shared coordinate already connects; nearby parallel paths and T branches are not snapped.
        var ends: [End] = [], buckets: [Cell: [Int]] = [:]
        func cell(_ point: Vector, _ plane: Plane) -> Cell {
            Cell(plane: plane, x: Int(floor(point.x)), y: Int(floor(point.y)))
        }
        for index in lines.indices where lines[index].count >= 2 {
            let surface = input.paths[index], line = lines[index]
            let material = Material(plane: surface.plane, kind: surface.kind, paved: surface.paved)
            for start in [true, false] {
                let point = start ? line[0] : line[line.count - 1]
                let neighbour = start ? line[1] : line[line.count - 2]
                let end = End(line: index, start: start, point: point,
                    outward: (point - neighbour).unit, material: material)
                buckets[cell(point, surface.plane), default: []].append(ends.count)
                ends.append(end)
            }
        }
        var nearest: [Int: Int] = [:]
        for (index, end) in ends.enumerated() {
            try Task.checkCancellation()
            let key = cell(end.point, end.material.plane)
            var candidates: [Int] = []
            for x in -1...1 { for y in -1...1 {
                candidates += buckets[Cell(plane: key.plane, x: key.x + x, y: key.y + y)] ?? []
            } }
            // Dense or already shared nodes are intentionally left untouched.
            guard candidates.count <= 24, !candidates.contains(where: {
                $0 != index && (ends[$0].point - end.point).length < 0.08
            }) else { continue }
            var distance = 0.65
            for other in candidates where other != index {
                let peer = ends[other], delta = peer.point - end.point
                guard peer.line != end.line, peer.material == end.material, delta.length > 0.08,
                      delta.length < distance, end.outward.dot(peer.outward) < -0.94,
                      end.outward.dot(delta.unit) > 0.8, peer.outward.dot(delta.unit) < -0.8 else { continue }
                let bridge = DetailedRoadSurfaceGeometry.path([end.point, peer.point], closed: false)
                    .copy(strokingWithWidth: 0.15, lineCap: .round, lineJoin: .round, miterLimit: 1)
                if let road = roadMasks[key.plane], !bridge.intersection(road).isEmpty { continue }
                nearest[index] = other; distance = delta.length
            }
        }
        for (index, other) in nearest where index < other && nearest[other] == index {
            let a = ends[index], b = ends[other], middle = (a.point + b.point) * 0.5
            lines[a.line][a.start ? 0 : lines[a.line].count - 1] = middle
            lines[b.line][b.start ? 0 : lines[b.line].count - 1] = middle
            connect(a.line, b.line)
        }
        let areaPaths = input.areas.map(polygon)
        let axes = lines.map { DetailedRoadSurfaceGeometry.path($0, closed: false) }
        for (areaIndex, area) in input.areas.enumerated() {
            try Task.checkCancellation()
            let outline = areaPaths[areaIndex]
            for (lineIndex, line) in input.paths.enumerated() where line.plane == area.plane {
                if lineIndex.isMultiple(of: 128) { try Task.checkCancellation() }
                let axis = axes[lineIndex]
                guard axis.boundingBoxOfPath.intersects(outline.boundingBoxOfPath),
                      !axis.lineIntersection(outline).isEmpty else { continue }
                connect(lineIndex, input.paths.count + areaIndex)
            }
            for peer in 0..<areaIndex where input.areas[peer].plane == area.plane {
                guard outline.boundingBoxOfPath.intersects(areaPaths[peer].boundingBoxOfPath),
                      !outline.intersection(areaPaths[peer]).isEmpty else { continue }
                connect(input.paths.count + areaIndex, input.paths.count + peer)
            }
        }
        var strips: [Patch: CGMutablePath] = [:]
        for index in lines.indices where lines[index].count >= 2 {
            try Task.checkCancellation()
            let surface = input.paths[index]
            let key = Patch(material: Material(plane: surface.plane, kind: surface.kind, paved: surface.paved), component: root(index))
            let path = DetailedRoadSurfaceGeometry.path(lines[index], closed: false)
                .copy(strokingWithWidth: surface.width, lineCap: .round, lineJoin: .round, miterLimit: 2)
            let aggregate = strips[key] ?? CGMutablePath()
            aggregate.addPath(path); strips[key] = aggregate
        }
        var surfaces = strips.mapValues { $0.normalized(using: .winding) }
        for (index, area) in input.areas.enumerated() {
            try Task.checkCancellation()
            let key = Patch(material: Material(plane: area.plane, kind: area.kind, paved: area.paved),
                component: root(input.paths.count + index))
            let path = areaPaths[index]
            surfaces[key] = surfaces[key].map { $0.union(path) } ?? path
        }
        var envelopes: [Region: CGPath] = [:]
        for key in surfaces.keys {
            guard var surface = surfaces[key] else { continue }
            let region = Region(plane: key.material.plane, component: key.component)
            if let road = roadMasks[region.plane] { surface = surface.subtracting(road) }
            surfaces[key] = surface
            envelopes[region] = envelopes[region].map { $0.union(surface) } ?? surface
        }
        var landings: [Plane: CGMutablePath] = [:]
        let ground = Plane(layer: 0, level: 0, bridge: false)
        if let asphalt = roadMasks[ground] {
            for (index, crossing) in input.crossings.enumerated() {
                try Task.checkCancellation()
                let center = project(crossing.point)
                // Crossing points do not always carry elevation. Overlapping planes
                // are ambiguous, so keep the provider symbol rather than painting below a bridge.
                guard !roadMasks.contains(where: { plane, path in
                    plane != ground && path.contains(CGPoint(x: center.x, y: center.y), using: .winding)
                }) else { continue }
                guard asphalt.contains(CGPoint(x: center.x, y: center.y), using: .winding) else { continue }
                // Rotation is the road/stripe axis. The crossing travels perpendicular to it.
                let angle = crossing.rotation * .pi / 180
                let along = Vector(x: cos(angle), y: -sin(angle))
                let across = along.left
                func inside(_ point: Vector) -> Bool {
                    asphalt.contains(CGPoint(x: point.x, y: point.y), using: .winding)
                }
                func edge(_ sign: Double) -> Double? {
                    var distance = 0.25
                    while distance <= 24 {
                        if !inside(center + along * (distance * sign)) {
                            var lower = max(0, distance - 0.25), upper = distance
                            for _ in 0..<7 {
                                let middle = (lower + upper) / 2
                                if inside(center + along * (middle * sign)) { lower = middle } else { upper = middle }
                            }
                            return lower
                        }
                        distance += 0.25
                    }
                    return nil
                }
                guard let left = edge(-1), let right = edge(1), left + right >= 1.5,
                      // A nearly longitudinal ray must not turn a point into a huge zebra.
                      left + right <= 32 else { continue }
                let stripeWidth = 0.5, period = 1.0, crossingWidth = 3.0
                let length = left + right
                let count = max(1, Int(floor((length + period - stripeWidth) / period)))
                let total = Double(count - 1) * period + stripeWidth
                let start = (right - left - total) / 2
                let paint = CGMutablePath()
                for stripe in 0..<count {
                    let a = start + Double(stripe) * period
                    let corners = [center + along * a - across * (crossingWidth / 2),
                        center + along * (a + stripeWidth) - across * (crossingWidth / 2),
                        center + along * (a + stripeWidth) + across * (crossingWidth / 2),
                        center + along * a + across * (crossingWidth / 2)]
                    paint.addPath(DetailedRoadSurfaceGeometry.path(corners))
                }
                let clipped = paint.intersection(asphalt)
                guard !clipped.isEmpty else { continue }
                try emit(clipped, plane: ground, part: "crossing")
                output.resolvedCrossings.append(index)
                // Open only the pedestrian outline where the observed crossing reaches it.
                let opening = DetailedRoadSurfaceGeometry.path([center - along * (left + 0.5),
                    center + along * (right + 0.5)], closed: false)
                    .copy(strokingWithWidth: crossingWidth, lineCap: .butt, lineJoin: .round, miterLimit: 1)
                let mask = landings[ground] ?? CGMutablePath()
                mask.addPath(opening); landings[ground] = mask
            }
        }
        let materials = surfaces.keys.sorted {
            let a = "\($0.material.plane.layer):\($0.material.plane.level):\($0.material.plane.bridge):\($0.component):\($0.material.kind):\(String(describing: $0.material.paved))"
            let b = "\($1.material.plane.layer):\($1.material.plane.level):\($1.material.plane.bridge):\($1.component):\($1.material.kind):\(String(describing: $1.material.paved))"
            return a < b
        }
        for key in materials {
            try Task.checkCancellation()
            if let surface = surfaces[key] {
                try emit(surface, plane: key.material.plane, part: "surface", kind: key.material.kind, paved: key.material.paved)
            }
        }
        for (region, surface) in envelopes {
            try Task.checkCancellation()
            var outline = surface.copy(strokingWithWidth: 0.16, lineCap: .round, lineJoin: .round, miterLimit: 2)
            if let road = roadMasks[region.plane] {
                // Subtracting asphalt closes the polygon at its mouth. That closing
                // edge is not a kerb across the sidewalk: leave just the road's casing.
                let casing = road.copy(strokingWithWidth: 0.8, lineCap: .round, lineJoin: .round, miterLimit: 2)
                outline = outline.subtracting(road.union(casing))
            }
            if let mask = landings[region.plane] { outline = outline.subtracting(mask) }
            try emit(outline, plane: region.plane, part: "edge")
        }
        return output
    }
}
#endif
