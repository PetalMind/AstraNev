#if os(iOS)
import Foundation
import MapLibre
import OSLog
import UIKit

@MainActor
final class DetailedRoadRenderer {
    private enum Group: String, CaseIterable { case surface, lanes, arrows }
    private let prefix = "naviastra-detailed-roads"
    private let provider: any DetailedRoadDataProvider
    private var layerIDs: [String] = []
    private var query: DetailedRoadQuery?
    private var task: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private var refreshedAt = Date.distantPast
    private var nextFetchAt = Date.distantPast
    private var generation = 0
    private var dark: Bool?
    private var requestedDark = false
    private var features: [Group: [MLNShape & MLNFeature]] = [:]
    private var spriteNames: Set<String> = []
    private let logger = Logger(subsystem: "NaviAstra", category: "DetailedRoads")

    init(provider: (any DetailedRoadDataProvider)? = nil) {
        self.provider = provider ?? DetailedRoadProviderFactory.make()
    }
    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
    func didLoadStyle(on map: MLNMapView) {
        layerIDs = []
        spriteNames = []
        dark = nil
        configure(on: map)
        applyAppearance(dark: requestedDark, on: map)
        publish(on: map)
    }
    func update(on map: MLNMapView, dark: Bool, enabled: Bool) {
        requestedDark = dark
        guard enabled else { stop(); return }
        configure(on: map)
        applyAppearance(dark: dark, on: map)
        // Native MVT scheduling and caching belong to MapLibre, never to an Overpass viewport loop.
        if case .vectorTiles = provider.sourceConfiguration { return }
        let bounds = map.visibleCoordinateBounds
        guard let requested = DetailedRoadQuery.visible(south: bounds.sw.latitude, west: bounds.sw.longitude,
            north: bounds.ne.latitude, east: bounds.ne.longitude, zoom: map.zoomLevel) else {
            if query != nil { stop(); query = nil; features = [:]; publish(on: map) }
            return
        }
        if let query, query.contains(south: bounds.sw.latitude, west: bounds.sw.longitude,
                                     north: bounds.ne.latitude, east: bounds.ne.longitude),
           task != nil || Date().timeIntervalSince(refreshedAt) < 24 * 60 * 60 || retryAfter > .now { return }
        let changed = query?.id != requested.id
        guard changed || (task == nil && retryAfter <= .now) else { return }
        stop()
        query = requested
        refreshedAt = .distantPast
        let token = generation
        task = Task { [weak self, weak map] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard let self, let map, self.generation == token else { return }
                if case .roads(let cached) = await self.provider.cachedData(in: requested) {
                    try await self.render(cached, query: requested, token: token, on: map)
                    if cached.isFresh {
                        self.refreshedAt = cached.fetchedAt; self.retryAfter = .distantPast; self.task = nil; return
                    }
                }
                guard self.retryAfter <= .now else { self.scheduleRetry(on: map); return }
                let delay = max(0, self.nextFetchAt.timeIntervalSinceNow)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                self.nextFetchAt = Date().addingTimeInterval(10)
                if case .roads(let snapshot) = try await self.provider.data(in: requested) {
                    try await self.render(snapshot, query: requested, token: token, on: map)
                    self.refreshedAt = snapshot.fetchedAt
                }
                guard self.generation == token else { return }
                self.retryAfter = .distantPast; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.retryAfter = Date().addingTimeInterval(60); self.refreshedAt = .distantPast; self.task = nil
                self.logger.debug("Detailed roads unavailable; retaining cached geometry: \(error.localizedDescription, privacy: .private)")
                self.scheduleRetry(on: map)
            }
        }
    }
    private func scheduleRetry(on map: MLNMapView?) {
        guard let map else { return }
        let delay = max(1, retryAfter.timeIntervalSinceNow)
        task = Task { [weak self, weak map] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, let map else { return }
            self.task = nil
            self.update(on: map, dark: self.requestedDark, enabled: true)
        }
    }
    private func shapeID(_ group: Group) -> String { prefix + "-" + group.rawValue + "-source" }
    private func collection(_ group: Group) -> MLNShapeCollectionFeature? {
        guard let shapes = features[group], !shapes.isEmpty else { return nil }
        return MLNShapeCollectionFeature(shapes: shapes)
    }
    private func publish(on map: MLNMapView) {
        guard case .shapes = provider.sourceConfiguration else { return }
        for group in Group.allCases {
            (map.style?.source(withIdentifier: shapeID(group)) as? MLNShapeSource)?.shape = collection(group)
        }
    }
    private func render(_ snapshot: DetailedRoadSnapshot, query: DetailedRoadQuery, token: Int, on map: MLNMapView) async throws {
        let graphics = try await DetailedRoadGeometryCache.shared.graphics(for: snapshot, in: query)
        try Task.checkCancellation()
        guard generation == token else { return }
        var nextFeatures: [Group: [MLNShape & MLNFeature]] = [:]
        var usedSprites: Set<String> = []
        for (index, graphic) in graphics.enumerated() {
            if index.isMultiple(of: 128) {
                await Task.yield(); try Task.checkCancellation()
                guard generation == token else { return }
            }
            var points = graphic.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let turnType = graphic.turnTypes.joined(separator: ";")
            let attributes: [String: Any] = [
                "kind": graphic.kind.rawValue, "level": graphic.level, "roadClass": graphic.roadClass,
                "renderLevel": graphic.renderLevel.rawValue, "bridge": graphic.bridge, "covered": graphic.covered,
                "confidence": graphic.confidence.rawValue, "directionality": graphic.directionality.rawValue,
                "laneType": graphic.laneType, "direction": graphic.direction.rawValue,
                "turnType": turnType, "bearing": graphic.bearing, "arrowScale": graphic.arrowScale
            ]
            if graphic.kind == .arrow {
                let point = MLNPointFeature(); point.coordinate = points[0]; point.attributes = attributes
                nextFeatures[.arrows, default: []].append(point)
                usedSprites.insert(prefix + "-arrow-" + turnType)
            } else if graphic.polygon {
                let polygon = MLNPolygonFeature(coordinates: &points, count: UInt(points.count))
                polygon.attributes = attributes; nextFeatures[.surface, default: []].append(polygon)
            } else {
                let line = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
                line.attributes = attributes; nextFeatures[.lanes, default: []].append(line)
            }
        }
        features = nextFeatures
        configure(on: map)
        if let style = map.style {
            for name in usedSprites where style.image(forName: name) == nil {
                if let image = image(for: name) { style.setImage(image, forName: name) }
            }
            for name in spriteNames.subtracting(usedSprites) { style.removeImage(forName: name) }
            spriteNames = usedSprites
        }
        applyAppearance(dark: requestedDark, on: map)
        publish(on: map)
    }

    private func configure(on map: MLNMapView) {
        guard let style = map.style else { return }
        let sourceIdentifier: String
        var sources: [Group: MLNSource] = [:]
        var sourceLayers: [Group: String] = [:]
        switch provider.sourceConfiguration {
        case .shapes:
            sourceIdentifier = shapeID(.surface)
            if style.source(withIdentifier: sourceIdentifier) == nil {
                for group in Group.allCases {
                    let source = MLNShapeSource(identifier: shapeID(group), shape: collection(group), options: [
                        .maximumZoomLevel: 19, .buffer: 64, .simplificationTolerance: 0.1
                    ])
                    style.addSource(source); sources[group] = source
                }
            }
        case .vectorTiles(let configuration):
            sourceIdentifier = prefix + "-tiles-source"
            if style.source(withIdentifier: sourceIdentifier) == nil {
                let source = MLNVectorTileSource(identifier: sourceIdentifier, configurationURL: configuration.tileJSONURL)
                style.addSource(source)
                for group in Group.allCases { sources[group] = source }
                sourceLayers = [.surface: configuration.surfaceLayer, .lanes: configuration.laneLayer, .arrows: configuration.arrowLayer]
            }
        }
        guard !sources.isEmpty else {
            if layerIDs.isEmpty { layerIDs = style.layers.map(\.identifier).filter { $0.hasPrefix(prefix) } }
            return
        }
        var anchor = style.layers.last {
            ($0 is MLNLineStyleLayer || $0 is MLNFillStyleLayer)
                && ($0 as? MLNVectorStyleLayer)?.sourceLayerIdentifier == "transportation"
        }
        let firstBridge = style.layers.first {
            $0 is MLNLineStyleLayer && $0.identifier.lowercased().contains("bridge")
                && ($0 as? MLNVectorStyleLayer)?.sourceLayerIdentifier == "transportation"
        }
        layerIDs = []
        for level in -3...5 {
            for kind in [DetailedRoadGraphic.Kind.casing, .surface, .edge, .separator, .center, .sharedBoundary, .arrow] {
                let id = "\(prefix)-\(level)-\(kind.rawValue)"
                let group: Group = kind == .arrow ? .arrows : (kind == .casing || kind == .surface ? .surface : .lanes)
                guard let source = sources[group] else { continue }
                let layer: MLNVectorStyleLayer
                if group == .surface {
                    let fill = MLNFillStyleLayer(identifier: id, source: source)
                    fill.fillAntialiased = NSExpression(forConstantValue: true)
                    fill.fillOpacity = fade(start: 16, finish: 17, maximum: 1); layer = fill
                } else if group == .arrows {
                    let symbol = MLNSymbolStyleLayer(identifier: id, source: source)
                    symbol.iconImageName = NSExpression(mglJSONObject: ["concat", prefix + "-arrow-", ["get", "turnType"]])
                    symbol.iconRotation = NSExpression(forKeyPath: "bearing")
                    symbol.iconRotationAlignment = NSExpression(forConstantValue: "map")
                    symbol.iconPitchAlignment = NSExpression(forConstantValue: "map")
                    symbol.iconScale = NSExpression(mglJSONObject: ["interpolate", ["exponential", 2], ["zoom"],
                        17.3, ["*", 0.55, ["get", "arrowScale"]], 18.2, ["get", "arrowScale"],
                        20, ["*", 3.4, ["get", "arrowScale"]]])
                    symbol.iconOpacity = fade(start: 17.3, finish: 18.2, maximum: 0.9)
                    symbol.iconAllowsOverlap = NSExpression(forConstantValue: false)
                    layer = symbol
                } else {
                    let line = MLNLineStyleLayer(identifier: id, source: source)
                    line.lineCap = NSExpression(forConstantValue: "round"); line.lineJoin = NSExpression(forConstantValue: "round")
                    line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 16, 0.35, 18, 0.95, 20, 1.5])
                    line.lineOpacity = fade(start: 16.8, finish: 18, maximum: kind == .edge ? 0.65 : 0.88)
                    if kind != .edge { line.lineDashPattern = NSExpression(forConstantValue: kind == .separator ? [5, 7] : [7, 5]) }
                    layer = line
                }
                layer.sourceLayerIdentifier = sourceLayers[group]
                layer.minimumZoomLevel = 16
                let confidences = kind == .arrow ? ["exact"] : (group == .surface ? ["exact", "derived", "estimated"] : ["exact", "derived"])
                layer.predicate = NSPredicate(format: "kind == %@ AND level == %d AND confidence IN %@ AND renderLevel != %@",
                                              kind.rawValue, level, confidences, "underground")
                if level <= 0, let firstBridge { style.insertLayer(layer, below: firstBridge) }
                else { if let previous = anchor { style.insertLayer(layer, above: previous) } else { style.addLayer(layer) }; anchor = layer }
                layerIDs.append(id)
            }
        }
        dark = nil
    }
    private func fade(start: Double, finish: Double, maximum: Double) -> NSExpression {
        NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], start, 0, finish, maximum])
    }
    private func applyAppearance(dark: Bool, on map: MLNMapView) {
        guard self.dark != dark, let style = map.style else { return }
        self.dark = dark
        for id in layerIDs {
            if let fill = style.layer(withIdentifier: id) as? MLNFillStyleLayer {
                let casing = id.hasSuffix("-casing")
                fill.fillColor = NSExpression(forConstantValue: UIColor(naviHex:
                    casing ? (dark ? 0x42434A : 0xD5D3CF) : (dark ? 0x26282D : 0xE8E9EC)))
            } else if let line = style.layer(withIdentifier: id) as? MLNLineStyleLayer {
                line.lineColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0xB8C6CB : 0xFFFFFF))
            }
        }
        for name in spriteNames { if let image = image(for: name) { style.setImage(image, forName: name) } }
    }

    /// Also supplies native MVT sprites through the map's missing-image delegate.
    func image(for name: String) -> UIImage? {
        let imagePrefix = prefix + "-arrow-"
        guard name.hasPrefix(imagePrefix) else { return nil }
        let turns = String(name.dropFirst(imagePrefix.count)).components(separatedBy: ";")
        let allowed: Set<String> = ["left", "slight_left", "sharp_left", "through", "right", "slight_right", "sharp_right", "reverse", "merge_to_left", "merge_to_right"]
        guard !turns.isEmpty, turns.count <= 4, turns.allSatisfy({ allowed.contains($0) }) else { return nil }
        spriteNames.insert(name)
        return UIGraphicsImageRenderer(size: CGSize(width: 12, height: 26)).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor(naviHex: requestedDark ? 0xB8C6CB : 0xFFFFFF).cgColor)
            cg.setLineWidth(1.6); cg.setLineCap(.round); cg.setLineJoin(.round)
            for turn in turns {
                let side: CGFloat = turn.contains("left") ? -1 : (turn.contains("right") ? 1 : 0)
                var tip = CGPoint(x: 6, y: 3), vector = CGPoint(x: 0, y: -1)
                var stem = [CGPoint(x: 6, y: 23), CGPoint(x: 6, y: 11)]
                if turn == "reverse" { stem += [CGPoint(x: 2, y: 7), CGPoint(x: 2, y: 15)]; tip = CGPoint(x: 2, y: 18); vector = CGPoint(x: 0, y: 1) }
                else if side != 0 {
                    if turn.hasPrefix("slight") || turn.hasPrefix("merge") { tip = CGPoint(x: 6 + side * 4, y: 5); vector = CGPoint(x: side * 0.55, y: -0.83) }
                    else if turn.hasPrefix("sharp") { tip = CGPoint(x: 6 + side * 4, y: 16); vector = CGPoint(x: side * 0.7, y: 0.7) }
                    else { tip = CGPoint(x: 6 + side * 4, y: 9); vector = CGPoint(x: side, y: 0) }
                }
                cg.move(to: stem[0]); for point in stem.dropFirst() { cg.addLine(to: point) }; cg.addLine(to: tip); cg.strokePath()
                let normal = CGPoint(x: -vector.y, y: vector.x)
                cg.move(to: CGPoint(x: tip.x - vector.x * 3 + normal.x * 2, y: tip.y - vector.y * 3 + normal.y * 2))
                cg.addLine(to: tip)
                cg.addLine(to: CGPoint(x: tip.x - vector.x * 3 - normal.x * 2, y: tip.y - vector.y * 3 - normal.y * 2)); cg.strokePath()
            }
        }
    }
}
#endif
