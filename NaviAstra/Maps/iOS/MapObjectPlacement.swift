#if os(iOS)
import MapLibre
import simd

struct MapObjectPose {
    var coordinate: CLLocationCoordinate2D
    var bearing = 0.0
    var scale = SIMD3<Double>(repeating: 1)
    var conifer = false
    var key: String {
        "\(Int((coordinate.latitude * 1e7).rounded())):\(Int((coordinate.longitude * 1e7).rounded())):\(Int(bearing.rounded())):\(scale):\(conifer)"
    }
    func horizontal(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let a = bearing * .pi / 180, x = p.x * scale.x, y = p.y * scale.y
        return SIMD2(cos(a) * x + sin(a) * y, -sin(a) * x + cos(a) * y)
    }
    func part(_ part: MapStreetFurnitureGeometry.Part) -> MapStreetFurnitureGeometry.Part {
        .init(outline: part.outline.map(horizontal), base: part.base * scale.z,
              top: part.top * scale.z, material: part.material)
    }
    func bounds(kind: MapStreetFurnitureGeometry.Kind) -> MapStreetFurnitureGeometry.Bounds {
        let b = MapStreetFurnitureGeometry.bounds(for: kind)
        let corners = [SIMD2(b.minimum.x, b.minimum.y), SIMD2(b.maximum.x, b.minimum.y),
                       SIMD2(b.maximum.x, b.maximum.y), SIMD2(b.minimum.x, b.maximum.y)].map(horizontal)
        return .init(minimum: SIMD3(corners.map(\.x).min()!, corners.map(\.y).min()!, 0),
                     maximum: SIMD3(corners.map(\.x).max()!, corners.map(\.y).max()!, b.maximum.z * scale.z))
    }
}

/// Matches only nearby, unambiguous observed edges. No road-facing direction is
/// guessed for signs or cameras, and a corner cannot select an entrance facade.
@MainActor
struct MapObjectPlacement {
    private struct Edge { let a: SIMD2<Double>; let b: SIMD2<Double> }
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var wallCells: [Cell: [Edge]] = [:]
    private var roadCells: [Cell: [Edge]] = [:]
    private var broadWalls: [Edge] = []
    private var broadRoads: [Edge] = []
    private let origin: CLLocationCoordinate2D
    private let longitudeScale: Double
    private var walls: [Edge] = []
    private var roads: [Edge] = []

    init(on map: MLNMapView) {
        origin = map.centerCoordinate
        longitudeScale = 111_319.4908 * cos(origin.latitude * .pi / 180)
        guard let style = map.style else { return }
        func append(_ line: MLNMultiPoint, into edges: inout [Edge]) {
            guard line.pointCount >= 2 else { return }
            for index in 1..<Int(line.pointCount) where edges.count < 5_000 {
                let first = line.coordinates[index - 1], last = line.coordinates[index]
                guard CLLocationCoordinate2DIsValid(first), CLLocationCoordinate2DIsValid(last) else { continue }
                let a = SIMD2((first.longitude - origin.longitude) * longitudeScale, (first.latitude - origin.latitude) * 111_319.4908)
                let b = SIMD2((last.longitude - origin.longitude) * longitudeScale, (last.latitude - origin.latitude) * 111_319.4908)
                guard simd_length(b - a) >= 0.5 else { continue }
                edges.append(Edge(a: a, b: b))
            }
        }
        if let source = style.source(withIdentifier: MapTilerEnvironmentStyle.buildingsSourceID) as? MLNVectorTileSource {
            let filter = NSCompoundPredicate(andPredicateWithSubpredicates: [MapObjectModelInput.groundPredicate,
                NSPredicate(format: "height_min == nil OR height_min == 0")])
            for feature in source.features(sourceLayerIdentifiers: ["building"], predicate: filter) {
                let polygons = (feature as? MLNPolygon).map { [$0] } ?? (feature as? MLNMultiPolygon)?.polygons ?? []
                for p in polygons { for ring in [p] + (p.interiorPolygons ?? []) { append(ring, into: &walls) } }
                if walls.count >= 5_000 { break }
            }
        }
        if let source = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource {
            let filter = MapObjectModelInput.groundPredicate
            for feature in source.features(sourceLayerIdentifiers: ["road"], predicate: filter) {
                let lines = (feature as? MLNPolyline).map { [$0] } ?? (feature as? MLNMultiPolyline)?.polylines ?? []
                for line in lines { append(line, into: &roads) }
                if roads.count >= 5_000 { break }
            }
        }
        func index(_ edges: [Edge]) -> ([Cell: [Edge]], [Edge]) {
            var cells: [Cell: [Edge]] = [:], broad: [Edge] = []
            for edge in edges {
                let minX = Int(floor(min(edge.a.x, edge.b.x) / 16)), maxX = Int(floor(max(edge.a.x, edge.b.x) / 16))
                let minY = Int(floor(min(edge.a.y, edge.b.y) / 16)), maxY = Int(floor(max(edge.a.y, edge.b.y) / 16))
                guard (maxX - minX + 1) * (maxY - minY + 1) <= 256 else { broad.append(edge); continue }
                for x in minX...maxX { for y in minY...maxY { cells[Cell(x: x, y: y), default: []].append(edge) } }
            }
            return (cells, broad)
        }
        (wallCells, broadWalls) = index(walls)
        (roadCells, broadRoads) = index(roads)
        walls.removeAll(); roads.removeAll()

    }

    func resolve(_ input: MapObjectModelPoint) -> MapObjectPose {
        var pose = MapObjectPose(coordinate: input.coordinate, bearing: input.bearing ?? 0,
                                 conifer: input.kind == .tree && input.leafType == "needleleaved")
        let b = MapStreetFurnitureGeometry.bounds(for: input.kind)
        func ratio(_ value: Double?, reference: Double, range: ClosedRange<Double>) -> Double {
            guard let value, range.contains(value), reference > 0 else { return 1 }
            return (value / reference * 100).rounded() / 100
        }
        let range: ClosedRange<Double> = input.kind == .tree ? 0.5...45 : 0.2...12
        pose.scale.x = ratio(input.width, reference: b.maximum.x - b.minimum.x, range: range)
        pose.scale.y = input.kind == .tree ? pose.scale.x : ratio(input.depth, reference: b.maximum.y - b.minimum.y, range: range)
        pose.scale.z = ratio(input.height, reference: b.maximum.z, range: range)
        let p = SIMD2((input.coordinate.longitude - origin.longitude) * longitudeScale,
                      (input.coordinate.latitude - origin.latitude) * 111_319.4908)
        func matches(_ edges: [Edge], radius: Double) -> [(point: SIMD2<Double>, edge: Edge, distance: Double)] {
            var result: [(SIMD2<Double>, Edge, Double)] = []
            for edge in edges {
                guard p.x >= min(edge.a.x, edge.b.x) - radius, p.x <= max(edge.a.x, edge.b.x) + radius,
                      p.y >= min(edge.a.y, edge.b.y) - radius, p.y <= max(edge.a.y, edge.b.y) + radius else { continue }
                let d = edge.b - edge.a, length = simd_length(d)
                let t = simd_dot(p - edge.a, d) / (length * length)
                guard (0...1).contains(t) else { continue }
                let q = edge.a + d * t, distance = simd_length(p - q)
                guard distance < radius else { continue }
                result.append((q, edge, distance))
            }
            return result.sorted { $0.2 < $1.2 }
        }
        func nearby(_ cells: [Cell: [Edge]], broad: [Edge]) -> [Edge] {
            let x = Int(floor(p.x / 16)), y = Int(floor(p.y / 16))
            var result = broad
            for dx in -1...1 { for dy in -1...1 { result += cells[Cell(x: x + dx, y: y + dy)] ?? [] } }
            return result
        }
        if input.kind == .entrance {
            let candidates = matches(nearby(wallCells, broad: broadWalls), radius: 1.5)
            if let match = candidates.first {
                let d = simd_normalize(match.edge.b - match.edge.a)
                let ambiguous = candidates.dropFirst().contains {
                    $0.distance < match.distance + 0.35 && abs(simd_dot(d, simd_normalize($0.edge.b - $0.edge.a))) < 0.95
                }
                if !ambiguous, simd_length(match.point - match.edge.a) > 0.65, simd_length(match.point - match.edge.b) > 0.65 {
                    let anchor = match.point + (simd_length(p - match.point) > 0.01 ? simd_normalize(p - match.point) * 0.12 : SIMD2<Double>(repeating: 0))
                    pose.coordinate = CLLocationCoordinate2D(latitude: origin.latitude + anchor.y / 111_319.4908,
                                                            longitude: origin.longitude + anchor.x / longitudeScale)
                    if input.bearing == nil { pose.bearing = atan2(-d.y, d.x) * 180 / .pi }
                }
            }
        } else if input.bearing == nil, [.bench, .stop, .charger, .parcelLocker].contains(input.kind) {
            let candidates = matches(nearby(roadCells, broad: broadRoads), radius: 8)
            if let match = candidates.first, match.distance > 1 {
                let d = simd_normalize(match.edge.b - match.edge.a)
                let ambiguous = candidates.dropFirst().contains {
                    $0.distance < match.distance + 1 && abs(simd_dot(d, simd_normalize($0.edge.b - $0.edge.a))) < 0.9
                }
                if !ambiguous {
                    let front = match.point - p
                    pose.bearing = atan2(front.x, front.y) * 180 / .pi
                }
            }
        }
        pose.bearing = pose.bearing.rounded()
        return pose
    }
}
#endif
