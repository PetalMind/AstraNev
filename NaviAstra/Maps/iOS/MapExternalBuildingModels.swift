#if os(iOS)
import MapLibre
import simd

/// Generic library architecture is decorative. Replace only a complete,
/// rectangular, classified footprint with a known height and a stable feature ID.
@MainActor
final class MapExternalBuildingModels {
    private struct Mask {
        let layer: MLNFillExtrusionStyleLayer
        let original: NSPredicate?
        let ids: [Any]
    }
    private var masks: [Mask] = []
    private(set) var instances: [MapEnvironmentModelInstance] = []
    private(set) var diagnostics = ""
    var excludedIdentifiers: Set<String> { Set(masks.flatMap(\.ids).map { String(describing: $0) }) }

    func restore() {
        for mask in masks where mask.layer.predicate != mask.original { mask.layer.predicate = mask.original }
    }

    func reset() { restore(); masks = []; instances = [] }

    func applyMasks() {
        for mask in masks {
            let exclusion = NSPredicate(mglJSONObject: ["!", ["in", ["id"], ["literal", mask.ids]]])
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mask.original, exclusion].compactMap { $0 })
            if mask.layer.predicate != predicate { mask.layer.predicate = predicate }
        }
    }

    func refresh(on map: MLNMapView, settings: MapSettings, availableTriangles: Int,
                 focus: CLLocationCoordinate2D? = nil, route: [CLLocationCoordinate2D] = [],
                 projection: MapFurnitureProjectionLayer.Snapshot? = nil) {
        instances = []
        let policy = MapEnvironmentModelPolicy(navigating: settings.context.isNavigating, constrained: MapDetailPolicy.constrained)
        diagnostics = "włączone=\(settings.overlays.buildings3D)"
        guard settings.overlays.buildings3D, settings.cameraMode == .threeD,
              settings.baseMap != .satellite, map.zoomLevel >= MapEnvironmentModelPolicy.minimumZoom,
              availableTriangles > 0, let style = map.style else { reset(); return }
        let layers = style.layers.compactMap { $0 as? MLNFillExtrusionStyleLayer }.filter {
            $0.sourceLayerIdentifier == "building" && $0.isVisible && map.zoomLevel >= Double($0.minimumZoomLevel)
                && map.zoomLevel < Double($0.maximumZoomLevel)
        }
        let viewport = map.bounds.inset(by: map.contentInset)
        let visibleArea = viewport.width > 10 && viewport.height > 10 ? viewport : map.bounds
        func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            projection?.groundPoint(at: coordinate) ?? map.convert(coordinate, toPointTo: map)
        }
        let loadingArea = map.bounds.insetBy(dx: -96, dy: -96)
        let proposedFocus = focus.map(point)
        let focusPoint = proposedFocus.flatMap { visibleArea.contains($0) ? $0 : nil }
            ?? CGPoint(x: visibleArea.midX, y: visibleArea.minY + visibleArea.height * (policy.navigating ? 0.7 : 0.5))
        let routePoints = route.prefix(64).map(point)
        var loaded = 0, considered = 0
        var choices: [(MapEnvironmentModelInstance, String, Any, Double)] = []
        for sourceID in Set(layers.compactMap(\.sourceIdentifier)).sorted() {
            guard let source = style.source(withIdentifier: sourceID) as? MLNVectorTileSource else { continue }
            // Read source geometry, not rendered geometry hidden by the previous mask.
            let allFeatures = source.features(sourceLayerIdentifiers: ["building"], predicate: MapObjectModelInput.groundPredicate)
            loaded += allFeatures.count
            // Overzoomed source tiles can contain thousands of distant outlines.
            // Only compare full geometry for nearby eligible IDs; retain every
            // fragment of those IDs so tile cuts still cannot masquerade as houses.
            let nearbyIDs = Set(allFeatures.compactMap { feature -> String? in
                guard let id = feature.identifier,
                      let height = Self.number(feature.attributes["height"] ?? feature.attributes["render_height"]),
                      (2.5...90).contains(height), CLLocationCoordinate2DIsValid(feature.coordinate) else { return nil }
                let type = feature.attributes["subclass"] as? String ?? feature.attributes["class"] as? String ?? ""
                guard !MapBuildingModelCatalog.families(type: type, height: height).isEmpty,
                      loadingArea.contains(point(feature.coordinate)) else { return nil }
                return String(describing: id)
            })
            let features = allFeatures.filter { feature in
                feature.identifier.map { nearbyIDs.contains(String(describing: $0)) } ?? false
            }
            considered += features.count
            let grouped = Dictionary(grouping: features) { $0.identifier.map { String(describing: $0) } ?? "" }
            let fragmented = Set(grouped.compactMap { id, parts -> String? in
                let outlines = Set(parts.map { feature -> String in
                    guard let polygon = feature as? MLNPolygon, polygon.pointCount <= 512 else { return "unsupported" }
                    guard (0..<Int(polygon.pointCount)).allSatisfy({ CLLocationCoordinate2DIsValid(polygon.coordinates[$0]) }) else { return "unsupported" }
                    return (0..<Int(polygon.pointCount)).map {
                        let c = polygon.coordinates[$0]
                        return "\(Int((c.latitude * 1e7).rounded())):\(Int((c.longitude * 1e7).rounded()))"
                    }.sorted().joined(separator: ";")
                })
                return outlines.count > 1 || outlines.contains("unsupported") ? id : nil
            })
            var seen = Set<String>()
            for feature in features {
                guard let id = feature.identifier, id is NSNumber || id is NSString,
                      !fragmented.contains(String(describing: id)),
                      let polygon = feature as? MLNPolygon, (polygon.interiorPolygons ?? []).isEmpty,
                      let fit = Self.footprint(polygon),
                      let height = Self.number(feature.attributes["height"] ?? feature.attributes["render_height"]),
                      height >= 2.5, height <= 90,
                      (Self.number(feature.attributes["height_min"] ?? feature.attributes["render_min_height"]) ?? 0) == 0,
                      feature.attributes["hide_3d"] as? Bool != true else { continue }
                let key = sourceID + ":" + String(describing: id)
                guard seen.insert(key).inserted else { continue }
                let a = feature.attributes
                let type = a["subclass"] as? String ?? a["class"] as? String ?? ""
                let families = MapBuildingModelCatalog.families(type: type, height: height)
                let levels = Self.number(a["building:levels"] ?? a["levels"])
                let screen = point(fit.coordinate)
                let angle = fit.bearing * .pi / 180
                let halfX = (abs(cos(angle)) * fit.width + abs(sin(angle)) * fit.depth) / 2
                let halfY = (abs(sin(angle)) * fit.width + abs(cos(angle)) * fit.depth) / 2
                let bounds = MapStreetFurnitureGeometry.Bounds(minimum: SIMD3(-halfX, -halfY, 0), maximum: SIMD3(halfX, halfY, height))
                let projectedRect = projection?.bounds(at: fit.coordinate, model: bounds)
                let span: Double
                if let projectedRect {
                    span = Double(max(projectedRect.width, projectedRect.height))
                } else {
                    let flatSpan = MapDetailPolicy.projectedSpan(at: fit.coordinate, meters: max(fit.width, fit.depth), on: map)
                    let projectedHeight = height * sin(map.camera.pitch * .pi / 180) / max(0.01, map.metersPerPoint(atLatitude: fit.coordinate.latitude))
                    span = max(flatSpan, projectedHeight)
                }
                guard span >= policy.buildingSpan,
                      projectedRect.map({ $0.intersects(visibleArea) }) ?? visibleArea.insetBy(dx: -24, dy: -24).contains(screen) else { continue }
                struct Match { let id: String; let width: Double; let depth: Double; let bearing: Double; let score: Double }
                var matches: [Match] = []
                for template in MapBuildingModelCatalog.templates {
                    guard !template.families.isDisjoint(with: families), template.heights.contains(height) else { continue }
                    if let levels, !template.levels.contains(Int(max(0, min(200, levels.rounded())))) { continue }
                    let scaleLimit = template.families.contains(.house) ? 2.0 : 2.8
                    for swapped in [false, true] {
                        let width = swapped ? fit.depth : fit.width, depth = swapped ? fit.width : fit.depth
                        let x = width / height / template.aspect.x, y = depth / height / template.aspect.y
                        guard x >= 0.5, y >= 0.5, x <= scaleLimit, y <= scaleLimit else { continue }
                        let seed = (key + template.id).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                        let score = abs(log(x)) + abs(log(y)) + Double(seed % 100) / 1_000
                        matches.append(Match(id: template.id, width: width, depth: depth,
                            bearing: fit.bearing + (swapped ? 90 : 0), score: score))
                    }
                }
                matches.sort { $0.score == $1.score ? $0.id < $1.id : $0.score < $1.score }
                let simplified = span < policy.detailedBuildingSpan
                guard let match = matches.first,
                      let mesh = MapEnvironmentMeshCatalog.mesh(match.id, simplified: simplified) else { continue }
                let pose = MapObjectPose(coordinate: fit.coordinate, bearing: match.bearing,
                    scale: SIMD3(match.width, match.depth, height))
                let instance = MapEnvironmentModelInstance(key: key, mesh: mesh, pose: pose, isBuilding: true,
                    roofColor: Self.color(a["roof_color"]))
                var score = hypot(screen.x - focusPoint.x, screen.y - focusPoint.y)
                if policy.navigating, routePoints.contains(where: { hypot($0.x - screen.x, $0.y - screen.y) < 90 }) { score *= 0.65 }
                choices.append((instance, sourceID, id, Double(score)))
            }
        }
        choices.sort { $0.3 == $1.3 ? $0.0.key < $1.0.key : $0.3 < $1.3 }
        var budget = min(availableTriangles, policy.buildingTriangles)
        var idsBySource: [String: [Any]] = [:]
        for (model, sourceID, id, _) in choices {
            guard instances.count < policy.maximumBuildings, model.mesh.triangleCount <= budget else { continue }
            // Duplicate clipped copies cannot generate two models for one feature.
            guard !instances.contains(where: { $0.key == model.key }) else { continue }
            instances.append(model); budget -= model.mesh.triangleCount
            idsBySource[sourceID, default: []].append(id)
        }
        let nextMasks = layers.compactMap { layer -> Mask? in
            guard let source = layer.sourceIdentifier, let ids = idsBySource[source], !ids.isEmpty else { return nil }
            let original = masks.first(where: { $0.layer === layer }).map(\.original) ?? layer.predicate
            return Mask(layer: layer, original: original, ids: ids)
        }
        for previous in masks {
            let retained = nextMasks.contains { $0.layer === previous.layer
                && Set($0.ids.map { String(describing: $0) }) == Set(previous.ids.map { String(describing: $0) }) }
            if !retained, previous.layer.predicate != previous.original { previous.layer.predicate = previous.original }
        }
        masks = nextMasks
        diagnostics = "warstwy=\(layers.count), rekordy=\(loaded), analizowane=\(considered), zgodne=\(choices.count)"
    }

    private static func number(_ value: Any?) -> Double? {
        let n = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return n.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func color(_ value: Any?) -> SIMD3<Float>? {
        guard let text = value as? String, text.hasPrefix("#"), text.count == 7,
              let hex = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return SIMD3(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
    }

    private struct Fit {
        let coordinate: CLLocationCoordinate2D
        let width: Double, depth: Double, bearing: Double
    }

    private static func footprint(_ polygon: MLNPolygon) -> Fit? {
        guard (5...16).contains(Int(polygon.pointCount)) else { return nil }
        let coordinates = (0..<Int(polygon.pointCount)).map { polygon.coordinates[$0] }
        guard coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) && abs($0.latitude) < 85 }) else { return nil }
        let origin = BuildingMeshGenerator.mercator(coordinates[0])
        let meters = BuildingMeshGenerator.circumference * cos(coordinates[0].latitude * .pi / 180)
        let worldPoints = coordinates.map(BuildingMeshGenerator.mercator)
        // A source-tile cut can look rectangular when only one fragment is loaded.
        // Conservatively retain native geometry along common source tile boundaries.
        for zoom in 12...16 {
            let tiles = pow(2.0, Double(zoom))
            for index in 1..<worldPoints.count {
                let a = worldPoints[index - 1] * tiles, b = worldPoints[index] * tiles
                if abs(a.x - b.x) < 1e-6 && abs(a.x - a.x.rounded()) < 1.0 / 8_192 { return nil }
                if abs(a.y - b.y) < 1e-6 && abs(a.y - a.y.rounded()) < 1.0 / 8_192 { return nil }
            }
        }
        var ring = coordinates.map { c -> SIMD2<Double> in
            let p = (BuildingMeshGenerator.mercator(c) - origin) * meters
            return SIMD2(p.x, -p.y)
        }
        guard simd_distance(ring[0], ring[ring.count - 1]) < 0.15 else { return nil }
        ring.removeLast()
        // Remove redundant collinear points without accepting concave outlines.
        var changed = true
        while changed && ring.count > 4 {
            changed = false
            for i in ring.indices {
                let a = ring[(i + ring.count - 1) % ring.count], b = ring[i], c = ring[(i + 1) % ring.count]
                let edge = c - a
                if simd_length(edge) > 0.1 && abs(edge.x * (b.y - a.y) - edge.y * (b.x - a.x)) / simd_length(edge) < 0.08 {
                    ring.remove(at: i); changed = true; break
                }
            }
        }
        guard ring.count == 4 else { return nil }
        let edges = ring.indices.map { ring[($0 + 1) % 4] - ring[$0] }
        let lengths = edges.map(simd_length)
        let tolerance = max(0.2, min(lengths[0], lengths[1]) * 0.025)
        guard lengths.allSatisfy({ (3...140).contains($0) }),
              abs(lengths[0] - lengths[2]) < tolerance, abs(lengths[1] - lengths[3]) < tolerance else { return nil }
        for i in 0..<4 {
            guard abs(simd_dot(edges[i], edges[(i + 1) % 4]) / (lengths[i] * lengths[(i + 1) % 4])) < 0.025 else { return nil }
        }
        let index = lengths[0] >= lengths[1] ? 0 : 1
        let width = lengths[index], depth = lengths[(index + 1) % 4]
        let center = ring.reduce(SIMD2<Double>.zero, +) / 4
        let normalized = origin + SIMD2(center.x, -center.y) / meters
        let coordinate = CLLocationCoordinate2D(latitude: atan(sinh(.pi * (1 - 2 * normalized.y))) * 180 / .pi,
                                                longitude: normalized.x * 360 - 180)
        var axis = edges[index]
        if axis.x < 0 || (abs(axis.x) < 0.001 && axis.y < 0) { axis = -axis }
        return Fit(coordinate: coordinate, width: width, depth: depth,
                   bearing: -atan2(axis.y, axis.x) * 180 / .pi)
    }
}
#endif
