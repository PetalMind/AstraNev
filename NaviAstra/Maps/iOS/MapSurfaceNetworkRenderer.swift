#if os(iOS)
import MapLibre
import OSLog
import UIKit

/// Joins the loaded vector geometry without additional network requests or routing changes.
@MainActor
final class MapSurfaceNetworkRenderer {
    private static let prefix = MapEnvironmentStyle.prefix + "network-"
    private static let sourceID = prefix + "source"
    private static let original = MapEnvironmentStyle.prefix + "planet-"
    private var task: Task<Void, Never>?
    private var revision = 0
    private var requestedKey: Int?
    private weak var outputSource: MLNShapeSource?
    private var appearanceKey = ""
    private var replacingPaths = false
    private var layerIDs: [String] = []
    private var fallbackMaxima: [String: Float] = [:]
    private let logger = Logger(subsystem: "NaviAstra", category: "SurfaceNetwork")

    func suspend() {
        revision &+= 1
        task?.cancel(); task = nil; requestedKey = nil
    }

    func configure(in style: MLNStyle) {
        suspend()
        outputSource = nil; appearanceKey = ""; replacingPaths = false
        fallbackMaxima = [:]; layerIDs = []
        guard style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) != nil,
              style.source(withIdentifier: Self.sourceID) == nil,
              let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) else { return }
        let source = MLNShapeSource(identifier: Self.sourceID, shape: nil, options: [
            .maximumZoomLevel: 22, .buffer: 128, .simplificationTolerance: 0.05
        ])
        style.addSource(source)
        // The original paths keep native tiles requested even while replaced.
        for sourceLayer in ["pathway", "pedestrian"] {
            let probe = MLNLineStyleLayer(identifier: Self.prefix + "probe-" + sourceLayer,
                source: planet)
            probe.sourceLayerIdentifier = sourceLayer
            probe.minimumZoomLevel = 18
            probe.lineOpacity = NSExpression(forConstantValue: 0)
            style.addLayer(probe)
        }
        for level in -3...5 { for bridge in [false, true] {
            let anchor = style.layer(withIdentifier: Self.original + "path-" + (bridge ? "bridge-" : "ground-") + "edge")
            for part in ["surface", "paving", "edge"] {
                let id = Self.prefix + "\(level)-\(bridge)-" + part
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.minimumZoomLevel = 18
                layer.fillAntialiased = NSExpression(forConstantValue: true)
                let filter = NSPredicate(format: "_layer == %d AND _bridge == %@ AND _part == %@", level,
                    NSNumber(value: bridge), part == "paving" ? "surface" : part)
                layer.predicate = part == "paving" ? NSCompoundPredicate(andPredicateWithSubpredicates: [
                    filter, NSPredicate(format: "paved == true")]) : filter
                if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
                layerIDs.append(id)
            }
        } }
        let crossing = MLNFillStyleLayer(identifier: Self.prefix + "crossing", source: source)
        crossing.minimumZoomLevel = 18
        crossing.predicate = NSPredicate(format: "_part == %@", "crossing")
        crossing.fillAntialiased = NSExpression(forConstantValue: true)
        if let symbol = style.layer(withIdentifier: Self.original + "point-crossing") {
            style.insertLayer(crossing, below: symbol)
        } else { style.addLayer(crossing) }
        layerIDs.append(crossing.identifier)
    }

    func refresh(on map: MLNMapView, settings: MapSettings, dark: Bool) {
        guard let style = map.style,
              let output = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
        if outputSource !== output {
            suspend(); outputSource = output; appearanceKey = ""; replacingPaths = false
        }
        applyAppearance(in: style, settings: settings, dark: dark)
        guard settings.baseMap != .satellite, map.zoomLevel >= 18,
              abs(map.centerCoordinate.latitude) < 80,
              let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource else {
            suspend(); output.shape = nil; replacePaths(false, in: style)
            (style.layer(withIdentifier: Self.original + "point-crossing") as? MLNSymbolStyleLayer)?.predicate = nil
            return
        }
        let filter = NSPredicate(format: "(indoor == nil OR indoor != true) AND (construction == nil OR construction != true) AND (brunnel == %@ OR ((brunnel == nil OR NOT (brunnel IN %@)) AND (layer == nil OR layer >= 0))) AND (level == nil OR level >= 0)", "bridge", ["bridge", "tunnel"])
        let pathFeatures = planet.features(sourceLayerIdentifiers: ["pathway"], predicate: filter)
        let areaFeatures = planet.features(sourceLayerIdentifiers: ["pedestrian"], predicate: filter)
        var paths: [MapSurfaceNetworkGeometry.Surface] = [], areas: [MapSurfaceNetworkGeometry.Surface] = []
        var roads: [MapSurfaceNetworkGeometry.Surface] = []
        var count = 0
        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0 }
        func surface(_ feature: MLNFeature, rings: [[DetailedRoad.Point]], road: Bool = false) -> MapSurfaceNetworkGeometry.Surface {
            let attributes = feature.attributes
            let kind = attributes["class"] as? String ?? "footway"
            let width: Double = ["track": 3.2, "cycleway": 2.4, "pedestrian": 3.0, "platform": 3.0][kind] ?? 2.0
            return .init(rings: rings, plane: .init(layer: number(attributes[road ? "level" : "layer"]),
                level: road ? 0 : number(attributes["level"]),
                bridge: road ? ((attributes["bridge"] as? NSNumber)?.boolValue ?? false) : attributes["brunnel"] as? String == "bridge"),
                kind: kind, paved: (attributes["paved"] as? NSNumber)?.boolValue, width: width)
        }
        func points(_ line: MLNMultiPoint) -> [DetailedRoad.Point] {
            (0..<Int(line.pointCount)).compactMap {
                let c = line.coordinates[$0]
                guard CLLocationCoordinate2DIsValid(c) else { return nil }
                return DetailedRoad.Point(latitude: c.latitude, longitude: c.longitude)
            }
        }
        func rings(_ polygon: MLNPolygon) -> [[DetailedRoad.Point]] {
            [points(polygon)] + (polygon.interiorPolygons ?? []).map(points)
        }
        for feature in pathFeatures {
            let lines: [MLNPolyline]
            if let line = feature as? MLNPolyline { lines = [line] }
            else if let multi = feature as? MLNMultiPolyline { lines = multi.polylines }
            else { continue }
            for line in lines {
                let coordinates = points(line)
                guard coordinates.count >= 2 else { continue }
                count += coordinates.count
                paths.append(surface(feature, rings: [coordinates]))
            }
        }
        for feature in areaFeatures {
            let polygons: [MLNPolygon]
            if let polygon = feature as? MLNPolygon { polygons = [polygon] }
            else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
            else { continue }
            for polygon in polygons {
                let coordinates = rings(polygon)
                count += coordinates.reduce(0) { $0 + $1.count }
                areas.append(surface(feature, rings: coordinates))
            }
        }
        let bounds = map.visibleCoordinateBounds
        let latitudeMargin = 100.0 / 111_320
        let longitudeMargin = latitudeMargin / max(0.1, cos(map.centerCoordinate.latitude * .pi / 180))
        func intersectsViewport(_ coordinates: [[DetailedRoad.Point]]) -> Bool {
            let points = coordinates.flatMap { $0 }
            guard bounds.sw.longitude < bounds.ne.longitude else { return true }
            guard let south = points.map(\.latitude).min(), let north = points.map(\.latitude).max(),
                  let west = points.map(\.longitude).min(), let east = points.map(\.longitude).max() else { return false }
            return north >= bounds.sw.latitude - latitudeMargin && south <= bounds.ne.latitude + latitudeMargin
                && east >= bounds.sw.longitude - longitudeMargin && west <= bounds.ne.longitude + longitudeMargin
        }
        var queriedSources = Set<String>()
        for layer in style.layers.compactMap({ $0 as? MLNFillStyleLayer }) where
            layer.identifier.hasPrefix("naviastra-detailed-roads-") && layer.identifier.hasSuffix("-surface") && layer.isVisible {
            guard let sourceID = layer.sourceIdentifier, queriedSources.insert(sourceID).inserted else { continue }
            let features: [MLNFeature]
            if let source = style.source(withIdentifier: sourceID) as? MLNShapeSource,
               let collection = source.shape as? MLNShapeCollectionFeature {
                features = collection.shapes.map { $0 as MLNFeature }
            } else if let source = style.source(withIdentifier: sourceID) as? MLNVectorTileSource,
                      let name = layer.sourceLayerIdentifier {
                features = source.features(sourceLayerIdentifiers: [name], predicate: NSPredicate(format: "kind == %@", "surface"))
            } else { continue }
            for feature in features where feature.attributes["kind"] as? String == "surface"
                && feature.attributes["renderLevel"] as? String != "underground"
                && ["exact", "derived", "estimated"].contains(feature.attributes["confidence"] as? String ?? "") {
                let polygons: [MLNPolygon]
                if let polygon = feature as? MLNPolygon { polygons = [polygon] }
                else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
                else { continue }
                for polygon in polygons {
                    let coordinates = rings(polygon)
                    guard intersectsViewport(coordinates) else { continue }
                    count += coordinates.reduce(0) { $0 + $1.count }
                    roads.append(surface(feature, rings: coordinates, road: true))
                }
            }
        }
        let crossingSource = style.source(withIdentifier: MapCrosswalkRenderer.sourceID) as? MLNShapeSource
        let crossingPoints = (crossingSource?.shape as? MLNShapeCollectionFeature)?.shapes.compactMap { $0 as? MLNPointFeature } ?? []
        let crossings: [MapSurfaceNetworkGeometry.Crossing] = crossingPoints.compactMap {
            guard let rotation = ($0.attributes["_crosswalkRotation"] as? NSNumber)?.doubleValue,
                  rotation.isFinite, CLLocationCoordinate2DIsValid($0.coordinate),
                  ($0.attributes["_crosswalkGround"] as? NSNumber)?.boolValue != false else { return nil }
            return .init(point: .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude), rotation: rotation)
        }
        // An over-budget snapshot keeps all native geometry, rather than replacing just a subset.
        guard count <= 20_000, paths.count + areas.count + roads.count <= 1_500, crossings.count <= 256,
              (paths + areas).allSatisfy({ (-3...5).contains($0.plane.layer) }) else {
            suspend(); output.shape = nil; replacePaths(false, in: style)
            (style.layer(withIdentifier: Self.original + "point-crossing") as? MLNSymbolStyleLayer)?.predicate = nil
            return
        }
        let input = MapSurfaceNetworkGeometry.Input(latitude: map.centerCoordinate.latitude,
            longitude: map.centerCoordinate.longitude, paths: paths, areas: areas, roads: roads, crossings: crossings)
        var hasher = Hasher()
        for collection in [paths, areas, roads] {
            let identities = collection.map { item -> Int in
                var content = Hasher()
                content.combine(item.plane); content.combine(item.kind); content.combine(item.paved)
                for ring in item.rings {
                    content.combine(ring.count)
                    for p in ring { content.combine(p.latitude); content.combine(p.longitude) }
                }
                return content.finalize()
            }.sorted()
            hasher.combine(identities)
        }
        for c in crossings { hasher.combine(c.point.latitude); hasher.combine(c.point.longitude); hasher.combine(c.rotation) }
        let key = hasher.finalize()
        guard requestedKey != key else { return }
        suspend(); requestedKey = key
        // Never leave a replacement with old tile coverage while a new snapshot is being assembled.
        output.shape = nil; replacePaths(false, in: style)
        (style.layer(withIdentifier: Self.original + "point-crossing") as? MLNSymbolStyleLayer)?.predicate = nil
        let token = revision
        task = Task { [weak self, weak map, weak output] in
            do {
                let worker = Task.detached(priority: .utility) { try MapSurfaceNetworkGeometry.build(input) }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, let map, let output, self.revision == token,
                      map.style?.source(withIdentifier: Self.sourceID) === output else { return }
                var shapes: [MLNShape] = []
                for (index, graphic) in result.graphics.enumerated() {
                    if index.isMultiple(of: 128) {
                        await Task.yield(); try Task.checkCancellation()
                        guard self.revision == token, map.style?.source(withIdentifier: Self.sourceID) === output else { return }
                    }
                    let rings = graphic.rings.map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
                    guard var outer = rings.first, outer.count >= 4 else { continue }
                    let holes = rings.dropFirst().map { ring -> MLNPolygon in
                        var coordinates = ring
                        return MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
                    }
                    let polygon = MLNPolygonFeature(coordinates: &outer, count: UInt(outer.count), interiorPolygons: holes)
                    var attributes: [String: Any] = ["_part": graphic.part, "_layer": graphic.plane.layer,
                        "_bridge": graphic.plane.bridge, "class": graphic.kind]
                    if let paved = graphic.paved { attributes["paved"] = paved }
                    polygon.attributes = attributes; shapes.append(polygon)
                }
                output.shape = MLNShapeCollectionFeature(shapes: shapes)
                if let style = map.style {
                    self.replacePaths(!paths.isEmpty || !areas.isEmpty, in: style)
                    let identities = result.resolvedCrossings.map { index in
                        MapCrosswalkRenderer.identity(latitude: crossings[index].point.latitude, longitude: crossings[index].point.longitude)
                    }
                    (style.layer(withIdentifier: Self.original + "point-crossing") as? MLNSymbolStyleLayer)?.predicate = identities.isEmpty ? nil
                        : NSPredicate(format: "NOT (_crosswalkIdentity IN %@)", identities)
                }
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.task = nil
                self.logger.debug("Surface network retained native geometry: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func replacePaths(_ enabled: Bool, in style: MLNStyle) {
        guard replacingPaths != enabled else { return }
        replacingPaths = enabled
        for layer in style.layers {
            let id = layer.identifier
            let path = id.hasPrefix(Self.original + "path-") && !id.hasSuffix("steps")
            guard path || ["pedestrian", "pedestrian-bridge", "pedestrian-pattern"].contains(where: { id == Self.original + $0 }) else { continue }
            if enabled { fallbackMaxima[id] = layer.maximumZoomLevel; layer.maximumZoomLevel = 18 }
            else if let maximum = fallbackMaxima.removeValue(forKey: id) { layer.maximumZoomLevel = maximum }
        }
    }

    private func applyAppearance(in style: MLNStyle, settings: MapSettings, dark: Bool) {
        let key = "\(dark):\(settings.context)"
        guard appearanceKey != key else { return }
        appearanceKey = key
        let quiet = settings.context == .driving ? 0.72 : 1.0
        let cycle = settings.context == .cycling
        func rgb(_ hex: UInt32) -> [Any] { ["rgb", (hex >> 16) & 255, (hex >> 8) & 255, hex & 255] }
        for id in layerIDs {
            guard let layer = style.layer(withIdentifier: id) as? MLNFillStyleLayer else { continue }
            if id.hasSuffix("crossing") {
                layer.fillColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0xB8C6CB : 0xFFFFFF))
                layer.fillOpacity = NSExpression(forConstantValue: 0.92)
            } else if id.hasSuffix("edge") {
                layer.fillColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0x42434A : 0xD5D3CF))
                // Keep coplanar surfaces out of the opaque depth-writing pass.
                layer.fillOpacity = NSExpression(forConstantValue: quiet * 0.995)
            } else if id.hasSuffix("paving") {
                layer.fillPattern = NSExpression(forConstantValue: MapEnvironmentStyle.prefix + "paving-" + (dark ? "night" : "day"))
                layer.fillOpacity = NSExpression(forConstantValue: settings.context == .driving ? 0.04 : 0.08)
            } else {
                layer.fillColor = NSExpression(mglJSONObject: ["case", ["==", ["get", "paved"], false],
                    rgb(dark ? 0x3B3932 : 0xE5DFD0), ["match", ["get", "class"],
                    "cycleway", rgb(cycle ? (dark ? 0x699594 : 0xB5D2C8) : (dark ? 0x333B3B : 0xE1E9DE)),
                    "pedestrian", rgb(dark ? 0x363538 : 0xEDE8DF), rgb(dark ? 0x313238 : 0xF4F1EC)]])
                // Keep coplanar surfaces out of the opaque depth-writing pass.
                layer.fillOpacity = NSExpression(forConstantValue: quiet * 0.995)
            }
        }
    }
}
#endif
