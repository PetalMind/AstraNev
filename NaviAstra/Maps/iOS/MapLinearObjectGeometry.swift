#if os(iOS)
import MapLibre
import simd

/// Observed centre lines only. Profiles are schematic unless explicit dimensions
/// are supplied. Chains join at identical, degree-two vertices of the same type.
@MainActor
enum MapLinearObjectGeometry {
    struct Output { var shapes: [MLNShape] = []; var key = "" }
    private struct Edge {
        var a: CLLocationCoordinate2D
        var b: CLLocationCoordinate2D
        let kind: String
        let lowered: Bool
        let width: Double
        let height: Double
        let count: Int?
        let uphill: Bool?
        var family: String { "\(kind):\(lowered):\(width):\(height):\(count ?? 0):\(uphill.map(String.init) ?? "")" }
    }
    private struct Segment {
        let edge: Edge
        let a: CLLocationCoordinate2D
        let b: CLLocationCoordinate2D
        let phase: Double
        let startNormal: SIMD2<Double>
        let endNormal: SIMD2<Double>
        let key: String
        let score: Double
    }
    static let probeLayers = ["traffic_control", "pathway", "railway"]
    private static func id(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude * 1e7).rounded())):\(Int((c.longitude * 1e7).rounded()))"
    }
    private static func delta(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((b.longitude - a.longitude) * 111_319.4908 * cos(a.latitude * .pi / 180),
              (b.latitude - a.latitude) * 111_319.4908)
    }

    static func build(from source: MLNVectorTileSource?, on map: MLNMapView, settings: MapSettings) -> Output {
        guard settings.overlays.poi, map.zoomLevel >= 18, let source else { return Output() }
        var edges: [String: Edge] = [:], inspected = 0
        let kinds = ["kerb", "wall", "city_wall", "retaining_wall", "fence", "guard_rail", "handrail",
                     "barrier", "jersey_barrier", "cable_barrier", "chain", "bump", "hump", "cushion", "table"]
        for layer in probeLayers {
            let filter: NSPredicate
            switch layer {
            case "pathway": filter = NSPredicate(format: "class == %@ AND (brunnel == nil OR NOT (brunnel IN %@))", "steps", ["bridge", "tunnel"])
            case "railway": filter = NSPredicate(format: "class IN %@ AND (brunnel == nil OR NOT (brunnel IN %@))", ["rail", "tram", "light_rail", "narrow_gauge"], ["bridge", "tunnel"])
            default: filter = NSPredicate(format: "subclass IN %@", kinds)
            }
            let ground = NSCompoundPredicate(andPredicateWithSubpredicates: [filter, MapObjectModelInput.groundPredicate])
            for feature in source.features(sourceLayerIdentifiers: [layer], predicate: ground) {
                let lines = (feature as? MLNPolyline).map { [$0] } ?? (feature as? MLNMultiPolyline)?.polylines ?? []
                let attributes = feature.attributes
                func number(_ key: String) -> Double? {
                    let value = (attributes[key] as? NSNumber)?.doubleValue ?? (attributes[key] as? String).flatMap(Double.init)
                    return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                }
                let kind = layer == "railway" ? "rail" : (layer == "pathway" ? "steps" : attributes["subclass"] as? String ?? "barrier")
                let lowered = (attributes["lowered"] as? NSNumber)?.boolValue == true
                let width = number("width").flatMap { (0.05...15).contains($0) ? $0 : nil } ?? 0
                let height = number("height").flatMap { (0.02...8).contains($0) ? $0 : nil } ?? 0
                for line in lines where line.pointCount >= 2 {
                    for index in 1..<Int(line.pointCount) {
                        inspected += 1
                        guard inspected <= 8_000 else { break }
                        let a = line.coordinates[index - 1], b = line.coordinates[index]
                        guard CLLocationCoordinate2DIsValid(a), CLLocationCoordinate2DIsValid(b),
                              abs(a.latitude) < 85, abs(b.latitude) < 85,
                              simd_length(delta(a, b)) > 0.08 else { continue }
                        let uphill: Bool? = (attributes["incline"] as? String).flatMap { $0 == "up" ? true : ($0 == "down" ? false : nil) }
                        // Clamp before conversion: a finite API number can still exceed Int.max.
                        let count = number("step_count").map { Int(min(64, max(2, $0))) }
                        let edge = Edge(a: a, b: b, kind: kind, lowered: lowered, width: width,
                                        height: height, count: count, uphill: uphill)
                        let key = edge.family + ":" + [id(a), id(b)].sorted().joined(separator: ":")
                        edges[key] = edge
                    }
                    if inspected >= 8_000 { break }
                }
                if inspected >= 8_000 { break }
            }
            if inspected >= 8_000 { break }
        }
        // Join only unbranched observed vertices. No snapping across gaps or intersections.
        let all = edges.sorted { $0.key < $1.key }.map(\.value)
        var nodes: [String: [Int]] = [:]
        for (i, edge) in all.enumerated() {
            nodes[edge.family + ":" + id(edge.a), default: []].append(i)
            nodes[edge.family + ":" + id(edge.b), default: []].append(i)
        }
        var used: Set<Int> = [], chains: [[Edge]] = []
        let seeds = all.indices.sorted {
            let a = all[$0], b = all[$1]
            let first = (nodes[a.family + ":" + id(a.a)]?.count != 2 || nodes[a.family + ":" + id(a.b)]?.count != 2)
            let second = (nodes[b.family + ":" + id(b.a)]?.count != 2 || nodes[b.family + ":" + id(b.b)]?.count != 2)
            return first == second ? $0 < $1 : first
        }
        for seed in seeds where !used.contains(seed) {
            var first = all[seed]
            if nodes[first.family + ":" + id(first.a)]?.count == 2,
               nodes[first.family + ":" + id(first.b)]?.count != 2 { swap(&first.a, &first.b) }
            var chain = [first]; used.insert(seed)
            while let last = chain.last {
                let linked = nodes[last.family + ":" + id(last.b)] ?? []
                guard linked.count == 2, let next = linked.first(where: { !used.contains($0) }) else { break }
                var edge = all[next]
                if id(edge.a) != id(last.b) { swap(&edge.a, &edge.b) }
                used.insert(next); chain.append(edge)
            }
            chains.append(chain)
        }
        let viewport = map.bounds.inset(by: map.contentInset)
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        var segments: [Segment] = []
        for chain in chains {
            var phase = 0.0
            func normal(_ edge: Edge) -> SIMD2<Double> {
                let d = simd_normalize(delta(edge.a, edge.b)); return SIMD2(-d.y, d.x)
            }
            func joint(_ left: SIMD2<Double>, _ right: SIMD2<Double>) -> SIMD2<Double> {
                let sum = left + right
                guard simd_length(sum) > 0.1 else { return right }
                let n = simd_normalize(sum), factor = simd_dot(n, right)
                return factor > 0.4 ? n / factor : right
            }
            for (index, edge) in chain.enumerated() {
                let length = simd_length(delta(edge.a, edge.b))
                defer { phase += length }
                guard let (a, b, t0, t1) = clip(edge.a, edge.b, bounds: map.visibleCoordinateBounds) else { continue }
                let start = map.convert(a, toPointTo: map), end = map.convert(b, toPointTo: map)
                guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
                      CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(start.x - end.x)),
                             height: max(1, abs(start.y - end.y))).intersects(viewport),
                      hypot(start.x - end.x, start.y - end.y) >= 4 else { continue }
                let n = normal(edge)
                let startNormal = index > 0 && t0 == 0 ? joint(normal(chain[index - 1]), n) : n
                let endNormal = index + 1 < chain.count && t1 == 1 ? joint(n, normal(chain[index + 1])) : n
                let key = "line:\(edge.family):\(id(a)):\(id(b)):\(phase):\(startNormal):\(endNormal)"
                segments.append(Segment(edge: edge, a: a, b: b, phase: phase + length * t0,
                    startNormal: startNormal, endNormal: endNormal,
                    key: key, score: hypot((start.x + end.x) / 2 - center.x, (start.y + end.y) / 2 - center.y)))
            }
        }
        let constrained = MapDetailPolicy.constrained
        var remaining = constrained ? 1_600 : 4_000
        var output = Output()
        for segment in segments.sorted(by: { $0.score == $1.score ? $0.key < $1.key : $0.score < $1.score }).prefix(constrained ? 48 : 128) {
            var parts = parts(for: segment, detailed: !constrained && map.zoomLevel >= 19)
            if parts.count * 4 > remaining { parts = self.parts(for: segment, detailed: false) }
            guard !parts.isEmpty, parts.count * 4 <= remaining else { continue }
            remaining -= parts.count * 4; output.key += "\(segment.key):\(parts.count)|"
            for (index, part) in parts.enumerated() {
                var coordinates = MapStreetFurnitureGeometry.coordinates(for: part, at: segment.a)
                let shape = MLNPolygonFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                shape.identifier = "\(segment.key):\(index)" as NSString
                shape.attributes = ["_base": part.base, "_top": part.top, "_material": part.material, "_kind": "linear", "_service": false]
                output.shapes.append(shape)
            }
        }
        return output
    }

    private static func parts(for s: Segment, detailed: Bool) -> [MapStreetFurnitureGeometry.Part] {
        let delta = delta(s.a, s.b), length = simd_length(delta)
        guard length > 0.08, length < 2_000 else { return [] }
        let d = delta / length, n = SIMD2(-d.y, d.x), zero = SIMD2<Double>(repeating: 0)
        func beam(_ a: SIMD2<Double>, _ b: SIMD2<Double>, width: Double, base: Double, top: Double,
                  material: String = "steel", joined: Bool = false) -> MapStreetFurnitureGeometry.Part {
            let first = (joined ? s.startNormal : n) * width / 2, last = (joined ? s.endNormal : n) * width / 2
            return .init(outline: [a - first, b - last, b + last, a + first, a - first], base: base, top: top, material: material)
        }
        func spaced(_ step: Double, _ body: (Double) -> [MapStreetFurnitureGeometry.Part]) -> [MapStreetFurnitureGeometry.Part] {
            var result: [MapStreetFurnitureGeometry.Part] = []
            let first = ceil(s.phase / step) * step - s.phase
            for position in stride(from: first, to: length - 0.001, by: step).prefix(96) { result += body(position) }
            return result
        }
        let e = s.edge
        switch e.kind {
        case "kerb":
            return [beam(zero, delta, width: e.width > 0 ? e.width : 0.18, base: 0,
                         top: e.lowered ? 0.03 : (e.height > 0 ? e.height : 0.14), material: "stone", joined: true)]
        case "wall", "city_wall", "retaining_wall", "barrier":
            return [beam(zero, delta, width: e.width > 0 ? e.width : 0.25, base: 0,
                         top: e.height > 0 ? e.height : 1.3, material: "stone", joined: true)]
        case "jersey_barrier":
            let h = e.height > 0 ? e.height : 0.8
            return [beam(zero, delta, width: 0.50, base: 0, top: h * 0.25, material: "stone", joined: true),
                    beam(zero, delta, width: 0.32, base: h * 0.25, top: h * 0.6, material: "stone", joined: true),
                    beam(zero, delta, width: 0.18, base: h * 0.6, top: h, material: "stone", joined: true)]
        case "rail":
            var parts = [-0.7175, 0.7175].map { offset in
                beam(n * offset, delta + n * offset, width: 0.075, base: 0.10, top: 0.22, joined: true)
            }
            if detailed { parts += spaced(0.65) { t in
                let c = d * t
                return [beam(c - d * 0.13, c + d * 0.13, width: 2.35, base: 0.01, top: 0.10, material: "wood")]
            } }
            return parts
        case "steps":
            // Without rise/direction, render shallow tread ribs rather than inventing a hill.
            let count = min(64, max(2, e.count ?? Int(ceil(length / 0.32))))
            let width = e.width > 0 ? e.width : 1.6
            return (0..<count).map { index in
                let low = Double(index) / Double(count), high = Double(index + 1) / Double(count)
                return beam(delta * low, delta * high, width: width, base: 0, top: 0.045, material: "stone")
            }
        case "bump", "hump", "cushion", "table":
            let width = e.width > 0 ? e.width : (e.kind == "table" ? 2.0 : 0.7)
            let h = e.height > 0 ? min(0.3, e.height) : 0.09
            return (0..<5).map { i in
                let offset = (Double(i) - 2) * width / 5
                return beam(n * offset, delta + n * offset, width: width / 5,
                            base: 0, top: h * (1 - abs(Double(i) - 2) / 3), material: "stone")
            }
        default:
            let fence = e.kind == "fence", chain = ["chain", "cable_barrier"].contains(e.kind)
            let height = e.height > 0 ? e.height : (fence ? 1.35 : (e.kind == "handrail" ? 1 : 0.78))
            let width = chain ? 0.035 : (fence ? 0.055 : 0.10)
            var parts = [beam(zero, delta, width: width, base: height - (chain ? 0.035 : 0.09), top: height, joined: true)]
            if detailed && !chain { parts.append(beam(zero, delta, width: 0.055, base: height * 0.35, top: height * 0.35 + 0.06, joined: true)) }
            parts += spaced(detailed ? 2.4 : 8) { t in
                let c = d * t
                return [beam(c - d * 0.045, c + d * 0.045, width: 0.09, base: 0, top: height + 0.025)]
            }
            return parts
        }
    }

    private static func clip(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, bounds: MLNCoordinateBounds)
        -> (CLLocationCoordinate2D, CLLocationCoordinate2D, Double, Double)? {
        guard bounds.ne.longitude > bounds.sw.longitude, bounds.ne.longitude - bounds.sw.longitude < 180 else { return nil }
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        var start = 0.0, end = 1.0
        for (p, q) in [(-dx, a.longitude - bounds.sw.longitude), (dx, bounds.ne.longitude - a.longitude),
                       (-dy, a.latitude - bounds.sw.latitude), (dy, bounds.ne.latitude - a.latitude)] {
            if abs(p) < 1e-12 { if q < 0 { return nil }; continue }
            let t = q / p
            if p < 0 { start = max(start, t) } else { end = min(end, t) }
            if start >= end { return nil }
        }
        return (CLLocationCoordinate2D(latitude: a.latitude + dy * start, longitude: a.longitude + dx * start),
                CLLocationCoordinate2D(latitude: a.latitude + dy * end, longitude: a.longitude + dx * end), start, end)
    }
}
#endif
