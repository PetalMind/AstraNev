#if os(iOS)
import MapLibre
import CoreGraphics

/// Replaces only observed matching footprints, never the whole viewport when
/// the first Buildings tile arrives. Planet geometry remains available elsewhere.
@MainActor
final class MapBuildingFallbackRenderer {
    private let planet = MapDetailObservations<MLNPolygonFeature>()
    private let detailed = MapDetailObservations<MLNPolygon>()
    private var contentKey = ""
    private var replaced = Set<String>()

    func reset() { planet.reset(); detailed.reset(); contentKey = ""; replaced.removeAll() }

    func refresh(on map: MLNMapView, settings: MapSettings) {
        guard map.zoomLevel >= 15, settings.baseMap != .satellite, let style = map.style,
              let output = style.source(withIdentifier: MapTilerEnvironmentStyle.fallbackSourceID) as? MLNShapeSource,
              let source = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource else { return }
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
        // Native z15 spatial buckets avoid comparing every fallback against every building.
        var grid: [String: [String]] = [:]
        var footprints: [String: Footprint] = [:]
        for (key, polygon) in known {
            let bounds = polygon.overlayBounds
            guard CLLocationCoordinate2DIsValid(bounds.sw), CLLocationCoordinate2DIsValid(bounds.ne),
                  bounds.ne.latitude >= bounds.sw.latitude, bounds.ne.longitude >= bounds.sw.longitude,
                  bounds.ne.latitude - bounds.sw.latitude < 0.02,
                  bounds.ne.longitude - bounds.sw.longitude < 0.04 else { continue }
            footprints[key] = Footprint(polygon)
            for latitude in Int(floor(bounds.sw.latitude * 2_000))...Int(floor(bounds.ne.latitude * 2_000)) {
                for longitude in Int(floor(bounds.sw.longitude * 2_000))...Int(floor(bounds.ne.longitude * 2_000)) {
                    grid["\(latitude):\(longitude)", default: []].append(key)
                }
            }
        }
        // A concave footprint's center can lie outside it or in its courtyard.
        // Compare the complete footprints, querying every intersected spatial cell.
        replaced.formIntersection(fallback.keys)
        let selected = fallback.filter { key, polygon in
            guard !replaced.contains(key) else { return false }
            let footprint = Footprint(polygon)
            let bounds = polygon.overlayBounds
            var candidates = Set<String>()
            guard CLLocationCoordinate2DIsValid(bounds.sw), CLLocationCoordinate2DIsValid(bounds.ne),
                  bounds.ne.latitude >= bounds.sw.latitude, bounds.ne.longitude >= bounds.sw.longitude,
                  bounds.ne.latitude - bounds.sw.latitude < 0.02,
                  bounds.ne.longitude - bounds.sw.longitude < 0.04 else { return true }
            for latitude in Int(floor(bounds.sw.latitude * 2_000))...Int(floor(bounds.ne.latitude * 2_000)) {
                for longitude in Int(floor(bounds.sw.longitude * 2_000))...Int(floor(bounds.ne.longitude * 2_000)) {
                    candidates.formUnion(grid["\(latitude):\(longitude)"] ?? [])
                }
            }
            let overlaps = candidates.contains { candidate in
                candidate == key || footprints[candidate].map { footprint.overlaps($0) } == true
            }
            // Missing tiles are not evidence that a replacement disappeared.
            // Do not bring the coarse copy back until this observation leaves the cache.
            if overlaps { replaced.insert(key) }
            return !overlaps
        }.sorted { $0.key < $1.key }
        let key = selected.map { "\($0.key):\($0.value.attributes["height"] ?? 0)" }.joined(separator: "|")
        if key != contentKey { contentKey = key; output.shape = MLNShapeCollectionFeature(shapes: selected.map(\.value)) }
        style.layer(withIdentifier: MapTilerEnvironmentStyle.fallbackFootprintID)?.isVisible = true
        style.layer(withIdentifier: MapTilerEnvironmentStyle.fallbackBuildingID)?.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
    }

    private struct Footprint {
        let path: CGPath
        let rings: [[CGPoint]]

        init(_ polygon: MLNPolygon) {
            rings = ([polygon] + (polygon.interiorPolygons ?? [])).map { ring in
                (0..<Int(ring.pointCount)).map {
                    CGPoint(x: ring.coordinates[$0].longitude, y: ring.coordinates[$0].latitude)
                }
            }
            let path = CGMutablePath()
            for ring in rings {
                guard let first = ring.first else { continue }
                path.move(to: first)
                for point in ring.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            self.path = path
        }

        func overlaps(_ other: Footprint) -> Bool {
            let intersection = path.boundingBoxOfPath.intersection(other.path.boundingBoxOfPath)
            guard !intersection.isNull, intersection.width > 1e-9, intersection.height > 1e-9 else { return false }
            // Interior samples handle containment and coincident boundaries without
            // treating adjacent buildings that share a wall as duplicate geometry.
            func sharesInterior(_ a: Footprint, _ b: Footprint) -> Bool {
                for ring in a.rings where ring.count >= 3 {
                    for index in ring.indices {
                        let start = ring[index], end = ring[(index + 1) % ring.count]
                        let dx = end.x - start.x, dy = end.y - start.y
                        let length = hypot(dx, dy)
                        guard length > 1e-10 else { continue }
                        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                        for side in [-1.0, 1.0] {
                            let point = CGPoint(x: midpoint.x - side * dy / length * 2e-7,
                                                y: midpoint.y + side * dx / length * 2e-7)
                            if a.path.contains(point, using: .evenOdd) && b.path.contains(point, using: .evenOdd) { return true }
                        }
                    }
                }
                return false
            }
            if sharesInterior(self, other) || sharesInterior(other, self) { return true }
            // Partial overlap may cross near a corner, away from every midpoint.
            func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Double {
                (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            }
            for a in rings { for b in other.rings {
                for i in a.indices { for j in b.indices {
                    let p = a[i], q = a[(i + 1) % a.count], r = b[j], s = b[(j + 1) % b.count]
                    let c1 = cross(p, q, r), c2 = cross(p, q, s)
                    let c3 = cross(r, s, p), c4 = cross(r, s, q)
                    if c1 * c2 < -1e-28 && c3 * c4 < -1e-28 { return true }
                } }
            } }
            return false
        }
    }
}
#endif
