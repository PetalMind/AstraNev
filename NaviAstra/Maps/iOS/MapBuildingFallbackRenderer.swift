#if os(iOS)
import MapLibre
import CoreGraphics

/// Replaces only observed matching footprints, never the whole viewport when
/// the first Buildings tile arrives. Planet geometry remains available elsewhere.
@MainActor
final class MapBuildingFallbackRenderer {
    private let planet = MapDetailObservations<MLNPolygonFeature>()
    private let detailed = MapDetailObservations<MLNPolygon>()
    private var publishedHeights: [String: String]?
    private var requested: Snapshot?
    private var currentFallback: [String: MLNPolygonFeature] = [:]
    private weak var currentOutput: MLNShapeSource?
    private var work: Task<Void, Never>?
    private var replaced = Set<String>()

    func suspend() {
        work?.cancel()
        work = nil
        requested = nil
        currentFallback.removeAll()
    }

    func reset() {
        suspend()
        planet.reset()
        detailed.reset()
        publishedHeights = nil
        replaced.removeAll()
        currentOutput = nil
    }

    func refresh(on map: MLNMapView, settings: MapSettings) {
        guard map.zoomLevel >= 15, settings.baseMap != .satellite, let style = map.style,
              let output = style.source(withIdentifier: MapTilerEnvironmentStyle.fallbackSourceID) as? MLNShapeSource,
              let source = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource else { suspend(); return }
        if currentOutput !== output {
            reset()
            currentOutput = output
        }
        func polygons(_ features: [MLNFeature]) -> [(String, MLNPolygonFeature, CLLocationCoordinate2D)] {
            var result: [(String, MLNPolygonFeature, CLLocationCoordinate2D)] = []
            for feature in features {
                let parts: [MLNPolygon]
                if let polygon = feature as? MLNPolygon { parts = [polygon] }
                else if let multi = feature as? MLNMultiPolygon { parts = multi.polygons }
                else { continue }
                for polygon in parts where polygon.pointCount >= 4 && polygon.pointCount <= 512 {
                    guard MapDetailPolicy.contains(polygon.coordinate, on: map, margin: 256) else { continue }
                    let key = (0..<Int(polygon.pointCount)).map {
                        "\(polygon.coordinates[$0].latitude):\(polygon.coordinates[$0].longitude)"
                    }.sorted().joined(separator: ";")
                    let copy = MLNPolygonFeature(coordinates: polygon.coordinates, count: polygon.pointCount,
                                                 interiorPolygons: polygon.interiorPolygons)
                    copy.attributes = feature.attributes
                    copy.identifier = feature.identifier
                    result.append((key, copy, polygon.coordinate))
                }
            }
            return result
        }
        let filter = NSPredicate(format: "underground == nil OR underground != true")
        let observations = polygons(source.features(sourceLayerIdentifiers: ["building"], predicate: filter))
        let fallback = planet.merge(observations, on: map, limit: 2_000)
        let buildings = style.source(withIdentifier: MapTilerEnvironmentStyle.buildingsSourceID) as? MLNVectorTileSource
        let matches = polygons(buildings?.features(sourceLayerIdentifiers: ["building"], predicate: filter) ?? [])
        let known = detailed.merge(matches.map { ($0.0, $0.1 as MLNPolygon, $0.2) }, on: map, limit: 2_000)
        style.layer(withIdentifier: MapTilerEnvironmentStyle.fallbackFootprintID)?.isVisible = true
        style.layer(withIdentifier: MapTilerEnvironmentStyle.fallbackBuildingID)?.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD

        replaced.formIntersection(fallback.keys)
        currentFallback = fallback
        let snapshot = Snapshot(planet: fallback.mapValues(Self.geometry), detailed: known.mapValues(Self.geometry))
        if requested == snapshot {
            if work == nil { publish(to: output) }
            return
        }
        work?.cancel()
        work = nil
        requested = snapshot
        guard !known.isEmpty, replaced.count < fallback.count else { publish(to: output); return }
        let alreadyReplaced = replaced
        work = Task { [weak self, weak map, weak output] in
            let matches = await Self.matches(in: snapshot, skipping: alreadyReplaced)
            guard !Task.isCancelled, let self, let output,
                  map?.style?.source(withIdentifier: MapTilerEnvironmentStyle.fallbackSourceID) === output else { return }
            self.work = nil
            // Missing tiles are not evidence that a previously observed replacement disappeared.
            self.replaced.formUnion(matches)
            self.publish(to: output)
        }
    }

    private func publish(to output: MLNShapeSource) {
        let selected = currentFallback.filter { !replaced.contains($0.key) }
        let heights = selected.mapValues { "\($0.attributes["height"] ?? 0)" }
        guard publishedHeights != heights else { return }
        publishedHeights = heights
        output.shape = MLNShapeCollectionFeature(shapes: selected.sorted { $0.key < $1.key }.map(\.value))
    }

    private nonisolated struct Geometry: Equatable, Sendable {
        let rings: [[CGPoint]]
        let bounds: CGRect
    }

    private nonisolated struct Snapshot: Equatable, Sendable {
        let planet: [String: Geometry]
        let detailed: [String: Geometry]
    }

    // MapLibre objects stay on the main actor. The worker receives only copied coordinates.
    private static func geometry(_ polygon: MLNPolygon) -> Geometry {
        let rings = ([polygon] + (polygon.interiorPolygons ?? [])).map { ring in
            (0..<Int(ring.pointCount)).map {
                CGPoint(x: ring.coordinates[$0].longitude, y: ring.coordinates[$0].latitude)
            }
        }
        let bounds = polygon.overlayBounds
        guard CLLocationCoordinate2DIsValid(bounds.sw), CLLocationCoordinate2DIsValid(bounds.ne),
              bounds.ne.latitude >= bounds.sw.latitude, bounds.ne.longitude >= bounds.sw.longitude,
              bounds.ne.latitude - bounds.sw.latitude < 0.02,
              bounds.ne.longitude - bounds.sw.longitude < 0.04 else { return Geometry(rings: rings, bounds: .null) }
        return Geometry(rings: rings, bounds: CGRect(x: bounds.sw.longitude, y: bounds.sw.latitude,
            width: bounds.ne.longitude - bounds.sw.longitude, height: bounds.ne.latitude - bounds.sw.latitude))
    }

    private nonisolated struct Cell: Hashable {
        let latitude: Int
        let longitude: Int

        static func visit(in bounds: CGRect, _ visit: (Cell) -> Void) {
            for latitude in Int(floor(bounds.minY * 2_000))...Int(floor(bounds.maxY * 2_000)) {
                for longitude in Int(floor(bounds.minX * 2_000))...Int(floor(bounds.maxX * 2_000)) {
                    visit(Cell(latitude: latitude, longitude: longitude))
                }
            }
        }
    }

    @concurrent private static func matches(in snapshot: Snapshot, skipping: Set<String>) async -> Set<String> {
        var grid: [Cell: [String]] = [:]
        for (key, geometry) in snapshot.detailed where !geometry.bounds.isNull {
            if Task.isCancelled { return [] }
            Cell.visit(in: geometry.bounds) { grid[$0, default: []].append(key) }
        }
        var matches = Set<String>()
        var detailedFootprints: [String: Footprint] = [:]
        for (key, geometry) in snapshot.planet where !geometry.bounds.isNull && !skipping.contains(key) {
            if Task.isCancelled { return [] }
            if let same = snapshot.detailed[key], !same.bounds.isNull {
                matches.insert(key)
                continue
            }
            var candidates = Set<String>()
            Cell.visit(in: geometry.bounds) { cell in
                if let entries = grid[cell] { candidates.formUnion(entries) }
            }
            var fallback: Footprint?
            for candidate in candidates {
                if Task.isCancelled { return [] }
                guard let other = snapshot.detailed[candidate] else { continue }
                let bounds = geometry.bounds.intersection(other.bounds)
                guard !bounds.isNull, bounds.width > 1e-9, bounds.height > 1e-9 else { continue }
                let lhs = fallback ?? Footprint(geometry.rings)
                let rhs = detailedFootprints[candidate] ?? Footprint(other.rings)
                fallback = lhs
                detailedFootprints[candidate] = rhs
                if lhs.overlaps(rhs) {
                    matches.insert(key)
                    break
                }
            }
        }
        return matches
    }

    private nonisolated struct Edge {
        let start: CGPoint
        let end: CGPoint
        let minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat

        init(_ start: CGPoint, _ end: CGPoint) {
            self.start = start
            self.end = end
            minX = min(start.x, end.x)
            maxX = max(start.x, end.x)
            minY = min(start.y, end.y)
            maxY = max(start.y, end.y)
        }

        func crosses(_ edge: Edge) -> Bool {
            guard maxX >= edge.minX, minX <= edge.maxX, maxY >= edge.minY, minY <= edge.maxY else { return false }
            func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
                (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            }
            return cross(start, end, edge.start) * cross(start, end, edge.end) < -1e-28 &&
                cross(edge.start, edge.end, start) * cross(edge.start, edge.end, end) < -1e-28
        }
    }

    private nonisolated struct Footprint {
        let path: CGPath
        let bounds: CGRect
        let edges: [Edge]
        let prefixMaxX: [CGFloat]

        init(_ rings: [[CGPoint]]) {
            let path = CGMutablePath()
            var edges: [Edge] = []
            for ring in rings {
                guard let first = ring.first else { continue }
                path.move(to: first)
                for point in ring.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                guard ring.count >= 3 else { continue }
                for i in ring.indices { edges.append(Edge(ring[i], ring[(i + 1) % ring.count])) }
            }
            self.path = path
            bounds = path.boundingBoxOfPath
            edges.sort { $0.minX < $1.minX }
            self.edges = edges
            var maximum = -CGFloat.infinity
            prefixMaxX = edges.map { edge in
                maximum = max(maximum, edge.maxX)
                return maximum
            }
        }

        func overlaps(_ other: Footprint) -> Bool {
            let intersection = bounds.intersection(other.bounds)
            guard !intersection.isNull, intersection.width > 1e-9, intersection.height > 1e-9 else { return false }
            // Only points in the common bounds can be inside both even-odd paths.
            if sharesInterior(with: other, in: intersection) || other.sharesInterior(with: self, in: intersection) { return true }
            // Detect corner crossings missed by both midpoint checks. Prefix maxima
            // retain long edges starting before the query and skip nonintersecting ranges.
            for edge in edges {
                if Task.isCancelled { return false }
                guard edge.maxX >= intersection.minX, edge.minX <= intersection.maxX,
                      edge.maxY >= intersection.minY, edge.minY <= intersection.maxY else { continue }
                var low = 0, high = other.edges.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if other.prefixMaxX[mid] < edge.minX { low = mid + 1 } else { high = mid }
                }
                for index in low..<other.edges.count {
                    let candidate = other.edges[index]
                    if candidate.minX > edge.maxX { break }
                    if edge.crosses(candidate) { return true }
                }
            }
            return false
        }

        private func sharesInterior(with other: Footprint, in intersection: CGRect) -> Bool {
            let offset = 2e-7
            let near = intersection.insetBy(dx: -offset, dy: -offset)
            for edge in edges {
                if Task.isCancelled { return false }
                let midpoint = CGPoint(x: (edge.start.x + edge.end.x) / 2, y: (edge.start.y + edge.end.y) / 2)
                guard midpoint.x >= near.minX, midpoint.x <= near.maxX,
                      midpoint.y >= near.minY, midpoint.y <= near.maxY else { continue }
                let dx = edge.end.x - edge.start.x, dy = edge.end.y - edge.start.y
                let length = hypot(dx, dy)
                guard length > 1e-10 else { continue }
                for side in [-1.0, 1.0] {
                    let point = CGPoint(x: midpoint.x - side * dy / length * offset,
                                        y: midpoint.y + side * dx / length * offset)
                    if point.x >= intersection.minX, point.x <= intersection.maxX,
                       point.y >= intersection.minY, point.y <= intersection.maxY,
                       path.contains(point, using: .evenOdd), other.path.contains(point, using: .evenOdd) { return true }
                }
            }
            return false
        }
    }
}
#endif
