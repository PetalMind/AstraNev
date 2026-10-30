#if os(iOS)
import MapLibre
import UIKit
import OSLog

/// Native silhouettes provide distant detail; bundled Kenney meshes replace
/// eligible nearby objects in the same camera, with bounded GPU instancing.
@MainActor
final class MapStreetFurnitureRenderer {
    private static let prefix = MapEnvironmentStyle.prefix + "furniture-"
    private static let sourceID = prefix + "source"
    private static let bodiesID = prefix + "bodies"
    private static let treesID = prefix + "trees"
    private static let probeID = prefix + "load"
    private static let treeProbeID = prefix + "load-trees"
    static let minimumZoom = MapEnvironmentModelPolicy.minimumZoom
    private static let maximumModels = 384
    private static let maximumTrees = 256
    private static let predicate = NSPredicate(format:
        "(class == %@ AND subclass IN %@) OR (class == %@ AND subclass IN %@) OR (class == %@ AND subclass IN %@)",
        "street", ["bench", "street_lamp", "traffic_signals", "fountain"],
        "protection", ["bollard", "kerb"], "access_control", ["entrance", "door"])
    var additionalPoints: [MapObjectModelPoint] = []
    private weak var outputSource: MLNShapeSource?
    private var refreshedAt = Date.distantPast
    private var iconKey = ""
    private var contentKey: String?
    private var refreshTask: Task<Void, Never>?
    private let observations = MapDetailObservations<Candidate>()
    private struct CachedGeometry {
        let shapes: [MLNShape]
        let cost: Int
        var used: TimeInterval
    }
    private var geometry: [String: CachedGeometry] = [:]
    private struct PlacementKey: Equatable {
        let style: ObjectIdentifier
        let roads: ObjectIdentifier?
        let buildings: ObjectIdentifier?
        let latitude: Int
        let longitude: Int
        let zoom: Int
    }
    private var placementScene: MapObjectPlacement?
    private var placementKey: PlacementKey?
    private var placementTime = Date.distantPast
    private var detailRequests: [String: (MapStreetFurnitureGeometry.Detail, Date)] = [:]
    private var modeled: [String: MapStreetFurnitureGeometry.Detail] = [:]
    private var projectionLayer: MapFurnitureProjectionLayer?
    private let logger = Logger(subsystem: "NaviAstra", category: "FurnitureModels")
    private var lastLog = Date.distantPast
    private var loggedLoadedPoints = false
    private struct Candidate {
        let coordinate: CLLocationCoordinate2D
        let kind: MapStreetFurnitureGeometry.Kind
        let key: String
        var input: MapObjectModelPoint? = nil
        var usesFallbackSymbol = true
        var pose: MapObjectPose? = nil
    }
    private static let iconsSourceID = prefix + "icons-source"
    private static let iconsID = prefix + "icons"
    private static let signalIconsID = prefix + "signal-icons"
    private static let treeIconsID = prefix + "tree-icons"
    private var signLayer: MapSignFaceLayer?
    private var lightLayer: MapStreetLampLightLayer?
    private var modelLayer: MapEnvironmentModelLayer?
    private let buildingModels = MapExternalBuildingModels()
    private var dark = false

    static func usesModels(in style: MLNStyle, settings: MapSettings) -> Bool {
        settings.cameraMode == .threeD && settings.baseMap != .satellite
            && style.layer(withIdentifier: bodiesID) != nil
    }

    static func replacesSymbol(_ kind: String, in style: MLNStyle, settings: MapSettings) -> Bool {
        ["bench", "street_lamp", "bollard", "traffic_signals", "fountain", "entrance"].contains(kind)
            && usesModels(in: style, settings: settings)
            && (style.source(withIdentifier: iconsSourceID) as? MLNShapeSource)?.shape != nil
    }

    static func replacesTrees(in style: MLNStyle, settings: MapSettings) -> Bool {
        usesModels(in: style, settings: settings)
            && (style.source(withIdentifier: iconsSourceID) as? MLNShapeSource)?.shape != nil
    }

    func pauseRefresh() {
        refreshTask?.cancel(); refreshTask = nil
    }

    func suspend() {
        pauseRefresh()
        modelLayer?.isVisible = false
        buildingModels.reset()
    }

    static func isSourceProbe(_ identifier: String) -> Bool {
        identifier == probeID || identifier == treeProbeID || identifier.hasPrefix(prefix + "probe-")
    }

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        outputSource = nil
        refreshedAt = .distantPast
        contentKey = nil
        iconKey = ""
        loggedLoadedPoints = false
        observations.reset()
        placementScene = nil
        placementKey = nil
        placementTime = .distantPast
        geometry.removeAll()
        modeled.removeAll()
        detailRequests.removeAll()
        lightLayer = nil
        signLayer = nil
        projectionLayer = nil
        modelLayer = nil
        buildingModels.reset()
    }

    func configure(in style: MLNStyle) {
        reset()
        if style.source(withIdentifier: Self.sourceID) != nil {
            signLayer = style.layer(withIdentifier: MapSignFaceLayer.layerID) as? MapSignFaceLayer
            lightLayer = style.layer(withIdentifier: MapStreetLampLightLayer.layerID) as? MapStreetLampLightLayer
            projectionLayer = style.layer(withIdentifier: MapFurnitureProjectionLayer.layerID) as? MapFurnitureProjectionLayer
            modelLayer = style.layer(withIdentifier: MapEnvironmentModelLayer.layerID) as? MapEnvironmentModelLayer
            return
        }
        if let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) {
            // Hidden symbols no longer request tiles. Keep the original points loaded
            // in 3D, including those that would otherwise lose icon-placement collisions.
            let probe = MLNCircleStyleLayer(identifier: Self.probeID, source: planet)
            probe.sourceLayerIdentifier = "street_furniture"
            probe.predicate = Self.predicate
            probe.minimumZoomLevel = Float(Self.minimumZoom)
            probe.circleRadius = NSExpression(forConstantValue: 1)
            probe.circleOpacity = NSExpression(forConstantValue: 0)
            probe.circleStrokeOpacity = NSExpression(forConstantValue: 0)
            probe.isVisible = false
            style.addLayer(probe)
            let treeProbe = MLNCircleStyleLayer(identifier: Self.treeProbeID, source: planet)
            treeProbe.sourceLayerIdentifier = "tree"
            treeProbe.minimumZoomLevel = Float(Self.minimumZoom)
            treeProbe.circleRadius = NSExpression(forConstantValue: 1)
            treeProbe.circleOpacity = NSExpression(forConstantValue: 0)
            treeProbe.circleStrokeOpacity = NSExpression(forConstantValue: 0)
            treeProbe.isVisible = false
            style.addLayer(treeProbe)
            for layer in MapObjectModelInput.tileLayers {
                let probe = MLNCircleStyleLayer(identifier: Self.prefix + "probe-" + layer, source: planet)
                probe.sourceLayerIdentifier = layer
                probe.minimumZoomLevel = Float(Self.minimumZoom)
                probe.circleRadius = NSExpression(forConstantValue: 1)
                probe.circleOpacity = NSExpression(forConstantValue: 0)
                probe.circleStrokeOpacity = NSExpression(forConstantValue: 0)
                probe.isVisible = false
                style.addLayer(probe)
            }
            for layer in MapLinearObjectGeometry.probeLayers {
                let lines = MLNLineStyleLayer(identifier: Self.prefix + "probe-" + layer, source: planet)
                lines.sourceLayerIdentifier = layer
                lines.minimumZoomLevel = 18
                lines.lineOpacity = NSExpression(forConstantValue: 0)
                lines.isVisible = false
                style.addLayer(lines)
            }
        }

        let source = MLNShapeSource(identifier: Self.sourceID, shape: nil,
            options: [.maximumZoomLevel: 22, .buffer: 64, .simplificationTolerance: 0])
        style.addSource(source)
        let bodies = MLNFillExtrusionStyleLayer(identifier: Self.bodiesID, source: source)
        bodies.predicate = NSPredicate(format: "_kind != %@ AND _external != YES", "tree")
        bodies.minimumZoomLevel = Float(Self.minimumZoom)
        bodies.fillExtrusionBase = NSExpression(forKeyPath: "_base")
        bodies.fillExtrusionHeight = NSExpression(forKeyPath: "_top")
        bodies.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
        bodies.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: 0)
        bodies.isVisible = false
        // Native 3D depth handles building occlusion. Compose after decorative
        // windows so they cannot paint over a lamp in front of a facade.
        // Labels and navigation remain above the physical map geometry.
        if let facade = style.layer(withIdentifier: MapBuildingFacadeLayer.layerID) {
            style.insertLayer(bodies, above: facade)
        } else if let building = style.layers.last(where: {
            ($0 as? MLNFillExtrusionStyleLayer)?.sourceLayerIdentifier == "building"
        }) {
            style.insertLayer(bodies, above: building)
        } else if let label = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
            style.insertLayer(bodies, below: label)
        } else {
            style.addLayer(bodies)
        }
        // Trees are landscape, independent of the POI switch, as their 2D circles were.
        let trees = MLNFillExtrusionStyleLayer(identifier: Self.treesID, source: source)
        trees.predicate = NSPredicate(format: "_kind == %@ AND _external != YES", "tree")
        trees.minimumZoomLevel = bodies.minimumZoomLevel
        trees.fillExtrusionBase = bodies.fillExtrusionBase
        trees.fillExtrusionHeight = bodies.fillExtrusionHeight
        trees.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
        trees.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: 0)
        trees.isVisible = false
        style.insertLayer(trees, above: bodies)
        let models = MapEnvironmentModelLayer(identifier: MapEnvironmentModelLayer.layerID)
        models.isVisible = false
        style.insertLayer(models, above: trees)
        modelLayer = models
        let faces = MapSignFaceLayer(identifier: MapSignFaceLayer.layerID)
        style.insertLayer(faces, above: models)
        signLayer = faces
        let lights = MapStreetLampLightLayer(identifier: MapStreetLampLightLayer.layerID)
        style.insertLayer(lights, above: faces)
        lightLayer = lights
        let projection = MapFurnitureProjectionLayer(identifier: MapFurnitureProjectionLayer.layerID)
        style.insertLayer(projection, above: lights)
        projectionLayer = projection
        let icons = MLNShapeSource(identifier: Self.iconsSourceID, shape: nil, options: nil)
        style.addSource(icons)
        for (id, signals) in [(Self.iconsID, false), (Self.signalIconsID, true)] {
            let symbols = MLNSymbolStyleLayer(identifier: id, source: icons)
            symbols.minimumZoomLevel = signals ? 18 : 18.5
            symbols.predicate = signals
                ? NSPredicate(format: "_kind IN %@", ["traffic_signals", "entrance"])
                : NSPredicate(format: "NOT (_kind IN %@)", ["tree", "traffic_signals", "entrance"])
            symbols.iconScale = NSExpression(forConstantValue: 0.5)
            symbols.iconAllowsOverlap = NSExpression(forConstantValue: false)
            symbols.iconRotationAlignment = NSExpression(forConstantValue: "map")
            symbols.iconPitchAlignment = NSExpression(forConstantValue: "map")
            symbols.iconOpacity = NSExpression(forKeyPath: "_opacity")
            style.addLayer(symbols)
        }
        let dots = MLNCircleStyleLayer(identifier: Self.treeIconsID, source: icons)
        dots.minimumZoomLevel = Float(Self.minimumZoom)
        dots.predicate = NSPredicate(format: "_kind == %@", "tree")
        dots.circleRadius = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 16, 1.5, 18, 2.5, 20, 4])
        dots.circleOpacity = NSExpression(forKeyPath: "_opacity")
        dots.circlePitchAlignment = NSExpression(forConstantValue: "map")
        style.addLayer(dots)
    }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool) {
        self.dark = dark
        refreshTask?.cancel(); refreshTask = nil
        let models = Self.usesModels(in: style, settings: settings)
        modelLayer?.updateVisibility(settings: settings, dark: dark)
        if !models { buildingModels.reset(); modelLayer?.isVisible = false }
        if !settings.overlays.buildings3D { buildingModels.reset() }
        style.layer(withIdentifier: Self.probeID)?.isVisible = models && settings.overlays.poi
        style.layer(withIdentifier: Self.treeProbeID)?.isVisible = models
        let palette = NSExpression(mglJSONObject: ["match", ["get", "_material"],
            "stone", dark ? "#727675" : "#C1BDB2",
            "signFace", dark ? "#A3ACAF" : "#DFE4E4",
            "cameraHousing", dark ? "#91814E" : "#C5AF62",
            "transit", dark ? "#486C90" : "#417BAC",
            "charger", dark ? "#477868" : "#659C7F",
            "locker", dark ? "#68737A" : "#87969F",
            "lockerDoor", dark ? "#859097" : "#B7C1C6",
            "wood", dark ? "#88715B" : "#A97D50",
            "bark", dark ? "#655444" : "#79604A",
            "foliage", dark ? "#456B51" : "#73985C",
            "foliageLight", dark ? "#4A7056" : "#799F62",
            "reflector", dark ? "#A5ADB1" : "#CDD2D1",
            "signalHousing", dark ? "#323C42" : "#374247",
            "signalLens", dark ? "#1B2427" : "#1E292C",
            "lens", dark ? "#E6D4A0" : "#D9E4E6",
            dark ? "#626D77" : "#4F5D65"])
        // Per-object screen size and hysteresis now control entry. A second
        // zoom fade would keep valid models invisible in normal navigation.
        let opacity = NSExpression(forConstantValue: 1)
        for identifier in [Self.bodiesID, Self.treesID] {
            guard let layer = style.layer(withIdentifier: identifier) as? MLNFillExtrusionStyleLayer else { continue }
            layer.isVisible = models && (identifier == Self.treesID || settings.overlays.poi)
            layer.fillExtrusionColor = palette
            layer.fillExtrusionOpacity = opacity
        }
        for id in [Self.iconsID, Self.signalIconsID] {
            let symbols = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer
            symbols?.isVisible = models && settings.overlays.poi
            symbols?.iconImageName = NSExpression(mglJSONObject: ["concat", MapEnvironmentStyle.prefix + "planet-",
                ["get", "_kind"], dark ? "-night" : "-day"])
        }
        let dots = style.layer(withIdentifier: Self.treeIconsID) as? MLNCircleStyleLayer
        dots?.isVisible = models
        dots?.circleColor = NSExpression(forConstantValue: UIColor(naviHex: dark ? 0x56725A : 0xA6C398))
    }

    func refresh(on map: MLNMapView, settings: MapSettings, enabled: Bool,
                 focus: CLLocationCoordinate2D? = nil, route: [CLLocationCoordinate2D] = [],
                 routeFilter: MapPOIRouteFilter = .unrestricted) {
        guard let style = map.style,
              let output = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource,
              let icons = style.source(withIdentifier: Self.iconsSourceID) as? MLNShapeSource else { return }
        let body = style.layer(withIdentifier: Self.bodiesID) as? MLNFillExtrusionStyleLayer
        let physical = NSPredicate(format: "_kind != %@ AND _external != YES", "tree")
        let street = NSPredicate(format: "_service != YES")
        let predicate: NSPredicate
        switch routeFilter {
        case .unrestricted: predicate = physical
        case .hidden: predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [physical, street])
        case .corridor(let corridor):
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [physical,
                NSCompoundPredicate(orPredicateWithSubpredicates: [street, corridor])])
        }
        if body?.predicate != predicate { body?.predicate = predicate }
        lightLayer?.updateVisibility(on: map, settings: settings, renderingEnabled: enabled)
        let visible = enabled && Self.usesModels(in: style, settings: settings)
        for id in [Self.bodiesID, Self.probeID, Self.iconsID, Self.signalIconsID, MapSignFaceLayer.layerID] {
            style.layer(withIdentifier: id)?.isVisible = visible && settings.overlays.poi
        }
        for id in [Self.treesID, Self.treeProbeID, Self.treeIconsID, MapFurnitureProjectionLayer.layerID] {
            style.layer(withIdentifier: id)?.isVisible = visible
        }
        for layer in MapObjectModelInput.tileLayers + MapLinearObjectGeometry.probeLayers {
            style.layer(withIdentifier: Self.prefix + "probe-" + layer)?.isVisible = visible && settings.overlays.poi
        }
        let nativeTrees = style.layer(withIdentifier: MapEnvironmentStyle.prefix + "planet-trees")
        let showsNativeTrees = !visible || map.zoomLevel < Self.minimumZoom || icons.shape == nil
        if nativeTrees?.isVisible != showsNativeTrees { nativeTrees?.isVisible = showsNativeTrees }
        guard visible, map.zoomLevel >= Self.minimumZoom else { suspend(); return }
        // The custom layer may become ready after the style's first appearance
        // pass. Synchronize its visibility flags before publishing masked models.
        modelLayer?.updateVisibility(settings: settings, dark: dark)
        modelLayer?.isVisible = true
        if outputSource !== output {
            outputSource = output
            contentKey = nil
            iconKey = ""
            observations.reset()
            geometry.removeAll()
            modeled.removeAll()
            placementScene = nil
            placementKey = nil
            placementTime = .distantPast
        }
        let policy = MapEnvironmentModelPolicy(navigating: settings.context.isNavigating, constrained: MapDetailPolicy.constrained)
        guard Date().timeIntervalSince(refreshedAt) >= policy.refreshInterval else { return }
        refreshTask?.cancel(); refreshTask = nil
        refreshedAt = .now
        let started = ProcessInfo.processInfo.systemUptime
        let constrained = MapDetailPolicy.constrained
        let planet = style.source(withIdentifier: MapTilerEnvironmentStyle.sourceID) as? MLNVectorTileSource
        let inset = map.bounds.inset(by: map.contentInset)
        let viewport = inset.width > 10 && inset.height > 10 ? inset : map.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let proposedFocus = focus.map { map.convert($0, toPointTo: map) }
        let focusPoint = proposedFocus.flatMap { viewport.contains($0) ? $0 : nil }
            ?? CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * (settings.context.isNavigating ? 0.72 : 0.5))
        let routePoints = route.map { map.convert($0, toPointTo: map) }.filter {
            $0.x.isFinite && $0.y.isFinite && viewport.insetBy(dx: -100, dy: -100).contains($0)
        }
        var incoming: [(String, Candidate, CLLocationCoordinate2D)] = []
        var incomingRank: [String: Double] = [:]
        for layer in ["street_furniture", "tree"] {
            if layer == "street_furniture", !settings.overlays.poi { continue }
            // Keep ineligible ground models as fallback symbols: their native
            // symbol layer is replaced by our per-object fallback source in 3D.
            for feature in planet?.features(sourceLayerIdentifiers: [layer], predicate: layer == "tree" ? nil : Self.predicate) ?? [] {
                guard let point = feature as? MLNPointFeature, CLLocationCoordinate2DIsValid(point.coordinate),
                      abs(point.coordinate.latitude) < 85,
                      let kind = MapStreetFurnitureGeometry.Kind(rawValue: layer == "tree" ? "tree" : ((point.attributes["subclass"] as? String == "door") ? "entrance" : (point.attributes["subclass"] as? String ?? ""))) else { continue }
                let screen = map.convert(point.coordinate, toPointTo: map)
                guard screen.x.isFinite, screen.y.isFinite,
                      map.bounds.insetBy(dx: -160, dy: -160).contains(screen) else { continue }
                let input = MapObjectModelPoint.metadata(point, kind: kind)
                let key = input.observationKey
                incoming.append((key, Candidate(coordinate: point.coordinate, kind: kind, key: key,
                    input: input, usesFallbackSymbol: kind != .kerb), point.coordinate))
                incomingRank[key] = hypot(Double(screen.x - focusPoint.x), Double(screen.y - focusPoint.y))
            }
        }
        for input in MapObjectModelInput.tiles(in: style) + additionalPoints {
            guard input.isAllowed(settings: settings, zoom: map.zoomLevel),
                  CLLocationCoordinate2DIsValid(input.coordinate), abs(input.coordinate.latitude) < 85 else { continue }
            let screen = map.convert(input.coordinate, toPointTo: map)
            guard screen.x.isFinite, screen.y.isFinite,
                  map.bounds.insetBy(dx: -160, dy: -160).contains(screen) else { continue }
            let key = input.observationKey
            incoming.append((key, Candidate(coordinate: input.coordinate, kind: input.kind, key: key,
                input: input, usesFallbackSymbol: false), input.coordinate))
            incomingRank[key] = hypot(Double(screen.x - focusPoint.x), Double(screen.y - focusPoint.y))
        }
        // Prefer identified external records for sign artwork and retain native fallback icons.
        incoming.sort {
            let a = $0.1.input, b = $1.1.input
            if (a?.sign != nil) != (b?.sign != nil) { return a?.sign != nil }
            if (a?.priority ?? 0) != (b?.priority ?? 0) { return (a?.priority ?? 0) > (b?.priority ?? 0) }
            let left = incomingRank[$0.0] ?? .greatestFiniteMagnitude
            let right = incomingRank[$1.0] ?? .greatestFiniteMagnitude
            return left == right ? $0.0 < $1.0 : left < right
        }
        var accepted: [(String, Candidate, CLLocationCoordinate2D)] = []
        var duplicateKeys: Set<String> = []
        var cells: [String: [Int]] = [:]
        let longitudeScale = 111_320 * cos(map.centerCoordinate.latitude * .pi / 180)
        for item in incoming {
            let c = item.1, input = c.input
            let x = Int(floor((item.2.longitude - map.centerCoordinate.longitude) * longitudeScale / 12))
            let y = Int(floor((item.2.latitude - map.centerCoordinate.latitude) * 111_320 / 12))
            let family = c.kind == .station ? "stop" : c.kind.rawValue
            let label = (input?.label ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            var duplicate: Int?
            for dx in -1...1 { for dy in -1...1 {
                for index in cells["\(family):\(x + dx):\(y + dy)"] ?? [] {
                    let peer = accepted[index].1, other = peer.input
                    let sameID = input?.canonicalID.isEmpty == false && input?.canonicalID == other?.canonicalID
                    let sameLabel = !label.isEmpty && label == (other?.label ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
                    let distance = CLLocation(latitude: item.2.latitude, longitude: item.2.longitude).distance(from:
                        CLLocation(latitude: peer.coordinate.latitude, longitude: peer.coordinate.longitude))
                    let distinctIDs = input?.canonicalID.isEmpty == false && other?.canonicalID.isEmpty == false && input?.canonicalID != other?.canonicalID
                    if !distinctIDs && (distance < 0.15 || (sameID && distance < 12) || (sameLabel && distance < 2)) { duplicate = index; break }
                }
            } }
            if let duplicate {
                if c.key != accepted[duplicate].1.key { duplicateKeys.insert(c.key) }
                if c.usesFallbackSymbol { accepted[duplicate].1.usesFallbackSymbol = true }
                if var retained = accepted[duplicate].1.input, let input {
                    retained.width = retained.width ?? input.width; retained.depth = retained.depth ?? input.depth
                    retained.height = retained.height ?? input.height; retained.bearing = retained.bearing ?? input.bearing
                    retained.leafType = retained.leafType ?? input.leafType
                    retained.groundModelAllowed = retained.groundModelAllowed && input.groundModelAllowed
                    for symbol in input.signs where !retained.signs.contains(symbol) && retained.signs.count < 3 { retained.extraSigns.append(symbol) }
                    accepted[duplicate].1.input = retained
                }
                continue
            }
            cells["\(family):\(x):\(y)", default: []].append(accepted.count)
            accepted.append(item)
        }
        accepted.sort { (incomingRank[$0.0] ?? 0) < (incomingRank[$1.0] ?? 0) }
        // Placement indexes geographic walls and roads, so rotating or tilting
        // the camera does not invalidate it. The existing two-second refresh
        // still picks up new tile contents within the same source objects.
        let placementCenter = map.centerCoordinate
        let nextPlacementKey = PlacementKey(
            style: ObjectIdentifier(style),
            roads: planet.map { ObjectIdentifier($0) },
            buildings: (style.source(withIdentifier: MapTilerEnvironmentStyle.buildingsSourceID)
                as? MLNVectorTileSource).map { ObjectIdentifier($0) },
            latitude: Int(placementCenter.latitude * 10_000),
            longitude: Int(placementCenter.longitude * 10_000),
            zoom: Int(map.zoomLevel * 4))
        if placementScene == nil || nextPlacementKey != placementKey || Date().timeIntervalSince(placementTime) > 2 {
            placementScene = MapObjectPlacement(on: map); placementKey = nextPlacementKey; placementTime = .now
        }
        let placement = placementScene!
        let winners = Dictionary(accepted.compactMap { item -> (String, String)? in
            guard let input = item.1.input, !input.canonicalID.isEmpty else { return nil }
            return (item.1.kind.rawValue + ":" + input.canonicalID, item.1.key)
        }, uniquingKeysWith: { first, _ in first })
        // Retention protects missing tiles, not records explicitly superseded by
        // the current deduplication pass (for example after OSM identity arrives).
        observations.remove(keys: duplicateKeys.subtracting(Set(accepted.map { $0.1.key })))
        let candidates = observations.merge(Array(accepted.prefix(1_200)), on: map, limit: 1_200).values
            .filter { $0.kind == .tree || ($0.input?.isAllowed(settings: settings, zoom: map.zoomLevel) ?? settings.overlays.poi) }
            .filter { candidate in
                guard let input = candidate.input, !input.canonicalID.isEmpty else { return true }
                return winners[candidate.kind.rawValue + ":" + input.canonicalID].map { $0 == candidate.key } ?? true
            }
            .map { candidate -> Candidate in
                var candidate = candidate
                candidate.pose = placement.resolve(candidate.input ?? .init(coordinate: candidate.coordinate, kind: candidate.kind))
                return candidate
            }.sorted { $0.key < $1.key }
        let projection = projectionLayer?.snapshot(on: map)
        typealias Detail = MapStreetFurnitureGeometry.Detail
        struct VisibleCandidate {
            let candidate: Candidate
            let detail: Detail
            let score: Double
            let span: Double
        }
        var eligible: [VisibleCandidate] = []
        var tooSmall = 0, offscreen = 0, unsupportedPlane = 0
        for candidate in candidates {
            guard candidate.input?.groundModelAllowed != false else { unsupportedPlane += 1; continue }
            let pose = candidate.pose ?? MapObjectPose(coordinate: candidate.coordinate)
            var model = pose.bounds(kind: candidate.kind)
            if candidate.kind == .sign, let input = candidate.input {
                model = .init(minimum: model.minimum, maximum: model.maximum + SIMD3(0, 0, Double(max(0, input.signs.count - 1)) * 0.74 * pose.scale.z))
            }
            let rect = projection?.bounds(at: pose.coordinate, model: model)
                ?? approximateBounds(at: pose.coordinate, model: model, on: map)
            guard rect.intersects(viewport) else { offscreen += 1; continue }
            let span = Double(max(rect.width, rect.height))
            let previous = modeled[candidate.key]
            guard span >= (previous == nil ? policy.entrySpan : policy.retainedSpan) else { tooSmall += 1; continue }
            var detail: Detail = span >= policy.fullSpan ? .full : (span >= policy.standardSpan ? .standard : .simple)
            if previous == .full, span >= policy.fullSpan - 3 { detail = .full }
            else if previous == .standard, span >= policy.standardSpan - 2, detail == .simple { detail = .standard }
            if constrained, detail == .full { detail = .standard }
            // Start new objects at their actual projected detail. Both upgrades
            // and downgrades of existing models must settle before replacing geometry.
            if let previous, detail != previous {
                if detailRequests[candidate.key]?.0 != detail { detailRequests[candidate.key] = (detail, .now) }
                if Date().timeIntervalSince(detailRequests[candidate.key]!.1) < 0.65 { detail = previous }
            } else { detailRequests.removeValue(forKey: candidate.key) }
            let point = CGPoint(x: rect.midX, y: rect.midY)
            var score = hypot(Double(point.x - focusPoint.x), Double(point.y - focusPoint.y))
                + hypot(Double(point.x - center.x), Double(point.y - center.y)) * 0.25
            if previous != nil { score *= 0.85 }
            if settings.context.isNavigating, distanceFromRoute(point, points: routePoints) < 60 { score *= 0.7 }
            eligible.append(VisibleCandidate(candidate: candidate, detail: detail, score: score, span: span))
        }
        eligible.sort { $0.score == $1.score ? $0.candidate.key < $1.candidate.key : $0.score < $1.score }
        // Counts remain bounded; ring vertices additionally bound walls/roof complexity.
        var streetBudget = constrained ? 8_000 : 20_000, treeBudget = constrained ? 6_000 : 20_000
        var streetCount = 0, treeCount = 0, budgetRejected = 0, spent = 0, budgetSimplified = 0
        var selected: [(Candidate, Detail)] = []
        let desired = Dictionary(uniqueKeysWithValues: eligible.map { ($0.candidate.key, $0.detail) })
        // Reserve cheap silhouettes first, so detailed nearby trees cannot
        // consume the entire budget before farther visible trees get a body.
        for item in eligible {
            let tree = item.candidate.kind == .tree
            guard tree ? treeCount < (constrained ? 64 : Self.maximumTrees)
                       : streetCount < (constrained ? 96 : Self.maximumModels) else { budgetRejected += 1; continue }
            let cost = MapStreetFurnitureGeometry.cost(for: item.candidate.kind, detail: .simple)
            guard cost <= (tree ? treeBudget : streetBudget) else { budgetRejected += 1; continue }
            if tree { treeCount += 1; treeBudget -= cost } else { streetCount += 1; streetBudget -= cost }
            spent += cost
            selected.append((item.candidate, .simple))
        }
        func allocateDetail(at index: Int, requested: Detail) {
            let candidate = selected[index].0
            let tree = candidate.kind == .tree
            var detail = requested
            let baseCost = MapStreetFurnitureGeometry.cost(for: candidate.kind, detail: selected[index].1)
            while MapStreetFurnitureGeometry.cost(for: candidate.kind, detail: detail) - baseCost > (tree ? treeBudget : streetBudget),
                  let cheaper = Detail(rawValue: detail.rawValue - 1) { detail = cheaper }
            let extra = MapStreetFurnitureGeometry.cost(for: candidate.kind, detail: detail) - baseCost
            if tree { treeBudget -= extra } else { streetBudget -= extra }
            spent += extra
            selected[index].1 = detail
        }
        // Reserve existing detail before admitting upgrades. Small ranking changes
        // must not repeatedly take the budget away from already visible models.
        for index in selected.indices {
            let key = selected[index].0.key
            let requested = desired[key] ?? .simple
            let retained = Detail(rawValue: min(modeled[key]?.rawValue ?? 0, requested.rawValue)) ?? .simple
            allocateDetail(at: index, requested: retained)
        }
        for index in selected.indices {
            let requested = desired[selected[index].0.key] ?? .simple
            allocateDetail(at: index, requested: requested)
            if selected[index].1.rawValue < requested.rawValue { budgetSimplified += 1 }
        }
        modeled = Dictionary(uniqueKeysWithValues: selected.map { ($0.0.key, $0.1) })
        var signFaces: [MapSignFace] = []
        var texturedSigns: Set<String> = []
        let faceLimit = constrained ? 16 : 48
        for (candidate, _) in selected where candidate.kind == .sign {
            guard let input = candidate.input else { continue }
            let faces = input.signs.enumerated().compactMap { index, symbol -> MapSignFace? in
                guard symbol.hasModelArtwork else { return nil }
                return MapSignFace(pose: candidate.pose ?? MapObjectPose(coordinate: candidate.coordinate),
                    symbol: symbol, key: candidate.key, verticalOffset: Double(index) * 0.74)
            }
            guard signLayer?.isReady == true, !faces.isEmpty, signFaces.count + faces.count <= faceLimit else { continue }
            signFaces += faces; texturedSigns.insert(candidate.key)
        }
        var shapes: [MLNShape] = []
        var externalModels: [MapEnvironmentModelInstance] = []
        var externalKeys = Set<String>()
        var triangleBudget = policy.totalTriangles
        var furnitureBudget = triangleBudget - (settings.overlays.buildings3D ? policy.buildingReserve : 0)
        if modelLayer?.isReady == true {
            // Preserve selection order: visible objects near the user/route have priority.
            for (candidate, detail) in selected {
                let pose = candidate.pose ?? MapObjectPose(coordinate: candidate.coordinate)
                guard let mesh = MapEnvironmentMeshCatalog.furniture(kind: candidate.kind, key: candidate.key,
                          conifer: pose.conifer, simplified: detail != .full || constrained),
                      mesh.triangleCount <= furnitureBudget,
                      candidate.kind == .tree || settings.overlays.poi else { continue }
                let bounds = MapStreetFurnitureGeometry.bounds(for: candidate.kind)
                var meshPose = pose
                if candidate.kind == .tree || candidate.kind == .bollard {
                    meshPose.scale *= SIMD3(bounds.maximum.x - bounds.minimum.x,
                        bounds.maximum.y - bounds.minimum.y, bounds.maximum.z)
                } else if candidate.kind == .bench {
                    let width = bounds.maximum.x - bounds.minimum.x
                    let height = width / mesh.aspect.x
                    meshPose.scale *= SIMD3(width, mesh.aspect.y * height, height)
                } else {
                    let height = bounds.maximum.z
                    meshPose.scale *= SIMD3(mesh.aspect.x * height, mesh.aspect.y * height, height)
                }
                externalModels.append(MapEnvironmentModelInstance(key: candidate.key, mesh: mesh,
                    pose: meshPose, isTree: candidate.kind == .tree))
                externalKeys.insert(candidate.key); triangleBudget -= mesh.triangleCount; furnitureBudget -= mesh.triangleCount
            }
            buildingModels.refresh(on: map, settings: settings, availableTriangles: triangleBudget,
                focus: focus, route: route, projection: projection)
            externalModels += buildingModels.instances
        } else { buildingModels.reset() }
        let now = ProcessInfo.processInfo.systemUptime
        for (candidate, detail) in selected.sorted(by: { $0.0.key < $1.0.key }) {
            let pose = candidate.pose ?? MapObjectPose(coordinate: candidate.coordinate)
            let cacheKey = "\(candidate.key):\(pose.key):\(String(describing: candidate.input?.signs)):\(texturedSigns.contains(candidate.key)):\(detail.rawValue):\(externalKeys.contains(candidate.key))"
            if geometry[cacheKey] == nil {
                var parts = MapStreetFurnitureGeometry.parts(for: candidate.kind, detail: detail, conifer: pose.conifer)
                if texturedSigns.contains(candidate.key), let input = candidate.input {
                    parts = Array(parts.prefix(1))
                    if let pole = parts.first {
                        parts[0] = .init(outline: pole.outline, base: pole.base, top: pole.top + Double(max(0, input.signs.count - 1)) * 0.74, material: pole.material)
                    }
                }
                let partsShapes: [MLNShape] = parts.enumerated().map { index, part in
                    var coordinates = MapStreetFurnitureGeometry.coordinates(for: pose.part(part), at: pose.coordinate)
                    let polygon = MLNPolygonFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                    polygon.identifier = "\(cacheKey):\(index)" as NSString
                    polygon.attributes = ["_base": part.base * pose.scale.z, "_top": part.top * pose.scale.z, "_material": part.material,
                        "_kind": candidate.kind.rawValue, "_service": candidate.input?.category != nil,
                        "_external": externalKeys.contains(candidate.key)]
                    return polygon
                }
                geometry[cacheKey] = CachedGeometry(shapes: partsShapes,
                    cost: MapStreetFurnitureGeometry.cost(for: candidate.kind, detail: detail), used: now)
            }
            geometry[cacheKey]?.used = now
            let cached = geometry[cacheKey]?.shapes ?? []
            for shape in cached { (shape as? MLNPolygonFeature)?.attributes["_external"] = externalKeys.contains(candidate.key) }
            shapes += cached
        }
        // A brief exit from view does not discard ready geometry. Time + LRU cost
        // bound the cache independently of the active model/vertex budgets.
        geometry = geometry.filter { now - $0.value.used < 30 }
        var cacheCost = 0
        let cacheLimit = constrained ? 32_000 : 80_000
        let retained = Set(geometry.sorted { $0.value.used > $1.value.used }.compactMap { key, entry -> String? in
            guard cacheCost + entry.cost <= cacheLimit else { return nil }
            cacheCost += entry.cost
            return key
        })
        geometry = geometry.filter { retained.contains($0.key) }
        let linear = MapLinearObjectGeometry.build(from: planet, on: map, settings: settings)
        let platforms = MapPlatformGeometry.build(from: planet, on: map, settings: settings)
        shapes += linear.shapes + platforms.shapes
        let buildingLayers = Set(style.layers.compactMap { layer -> String? in
            guard let building = layer as? MLNFillExtrusionStyleLayer,
                  building.sourceLayerIdentifier == "building", building.isVisible else { return nil }
            return building.identifier
        })
        let excluded = buildingModels.excludedIdentifiers
        let buildings = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: buildingLayers).filter {
            !excluded.contains($0.identifier.map { String(describing: $0) } ?? "")
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NAVIASTRA_MAP_AUDIT_CAMERA"] != nil, Date().timeIntervalSince(lastLog) >= 10 {
            let ids = buildings.prefix(8).map { String(describing: $0.identifier) }.joined(separator: ",")
            print("Maska modeli: budynki=\(buildings.count), wykluczone=\(excluded.count), identyfikatory=\(ids)")
        }
        #endif
        let occluders = buildings + shapes.compactMap { shape -> MLNFeature? in
            guard let feature = shape as? MLNFeature, feature.attributes["_external"] as? Bool != true else { return nil }
            return feature
        }
        let uploaded = modelLayer?.update(on: map, instances: externalModels, occluders: occluders, dark: dark) == true
        if uploaded { buildingModels.applyMasks() }
        else {
            buildingModels.reset()
            // Allocation/setup failure retains complete native bodies and symbols.
            for shape in shapes {
                (shape as? MLNPolygonFeature)?.attributes["_external"] = false
            }
        }
        if let facade = style.layer(withIdentifier: MapBuildingFacadeLayer.layerID) as? MapBuildingFacadeLayer {
            let ids = buildingModels.excludedIdentifiers
            if facade.externalModelIdentifiers != ids {
                facade.externalModelIdentifiers = ids
                facade.updateGeometry(on: map, layerIDs: buildingLayers, heightKey: "height", baseKey: "height_min")
            }
        }
        let key = linear.key + platforms.key + "\(uploaded):" + externalKeys.sorted().joined(separator: ";")
            + selected.map { "\($0.0.key):\($0.0.pose?.key ?? ""):\(String(describing: $0.0.input?.signs)):\(texturedSigns.contains($0.0.key)):\($0.1.rawValue)" }.sorted().joined(separator: "|")
        if key != contentKey { contentKey = key; output.shape = MLNShapeCollectionFeature(shapes: shapes) }
        let nextIconKey = candidates.map { "\($0.key):\(modeled[$0.key] != nil)" }.joined(separator: "|")
        if nextIconKey != iconKey || icons.shape == nil {
            iconKey = nextIconKey
            let fallback = candidates.filter(\.usesFallbackSymbol).map { candidate -> MLNPointFeature in
                let point = MLNPointFeature()
                point.coordinate = candidate.coordinate
                point.attributes = ["_kind": candidate.kind.rawValue,
                    "_opacity": modeled[candidate.key] != nil ? 0.0 : (candidate.kind == .tree ? 0.45 : 0.8)]
                return point
            }
            icons.shape = MLNShapeCollectionFeature(shapes: fallback)
        }
        for kind in ["bench", "street_lamp", "bollard", "traffic_signals", "fountain", "entrance"] {
            style.layer(withIdentifier: MapEnvironmentStyle.prefix + "planet-point-" + kind)?.isVisible = false
        }
        nativeTrees?.isVisible = false
        signLayer?.update(on: map, faces: signFaces)
        let treeFeatures = shapes.compactMap { $0 as? MLNFeature }.filter { $0.attributes["_kind"] as? String == "tree" }
        // The sorted model selection already prioritizes visible/user/route points.
        let lightCoordinates = selected.filter { $0.0.kind == .streetLamp }.prefix(constrained ? 24 : 64).map { candidate, _ in
            if uploaded, let model = externalModels.first(where: { $0.key == candidate.key }), let lens = model.mesh.lampLens {
                let offset = model.pose.horizontal(SIMD2(lens.x, lens.y))
                return MapStreetLampPlacement(coordinate: model.pose.coordinate,
                    offset: SIMD3(Float(offset.x), Float(-offset.y), Float(lens.z * model.pose.scale.z)))
            }
            let pose = candidate.pose ?? MapObjectPose(coordinate: candidate.coordinate)
            let offset = pose.horizontal(SIMD2(0, Double(MapStreetFurnitureGeometry.lampLensNorthOffset)))
            return MapStreetLampPlacement(coordinate: pose.coordinate,
                offset: SIMD3(Float(offset.x), Float(-offset.y), MapStreetFurnitureGeometry.lampLensHeight * Float(pose.scale.z)))
        }
        let furniture = shapes.compactMap { $0 as? MLNFeature }.filter {
            let kind = $0.attributes["_kind"] as? String
            return kind != "tree" && kind != "street_lamp" && kind != "sign" && ($0.attributes["_service"] as? Bool != true)
        }
        lightLayer?.updateGeometry(on: map, lamps: lightCoordinates, treeFeatures: treeFeatures, furnitureFeatures: furniture)
        detailRequests = detailRequests.filter { desired[$0.key] != nil }
        let awaitingDetail = detailRequests.values.contains { Date().timeIntervalSince($0.1) < 0.65 }
        if awaitingDetail, refreshTask == nil {
            refreshTask = Task { [weak self, weak map] in
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard let self, let map else { return }
                self.refreshTask = nil
                self.refresh(on: map, settings: settings, enabled: enabled, focus: focus, route: route, routeFilter: routeFilter)
            }
        }
        #if DEBUG
        if Date().timeIntervalSince(lastLog) >= 10 || (!loggedLoadedPoints && !candidates.isEmpty) {
            lastLog = .now
            loggedLoadedPoints = loggedLoadedPoints || !candidates.isEmpty
            let simple = selected.filter { $0.1 == .simple }.count
            let standard = selected.filter { $0.1 == .standard }.count
            let full = selected.filter { $0.1 == .full }.count
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let report = "Modele mapy: z=\(map.zoomLevel), punkty=\(candidates.count), proste=\(simple), średnie=\(standard), pełne=\(full), za_małe=\(tooSmall), poza_widokiem=\(offscreen), poza_gruntem=\(unsupportedPlane), limit=\(budgetRejected), uproszczone_przez_budżet=\(budgetSimplified), koszt=\(spent), zewnętrzne=\(uploaded ? externalModels.count : 0), budynki_zewnętrzne=\(buildingModels.instances.count), trójkąty=\(externalModels.reduce(0) { $0 + $1.mesh.triangleCount }), światła=\(lightCoordinates.count), macierz=\(projection != nil), ms=\(milliseconds)"
            logger.debug("\(report, privacy: .public)")
            print(report)
            if ProcessInfo.processInfo.environment["NAVIASTRA_MAP_AUDIT_CAMERA"] != nil {
                print("Widok modeli: środek=\(map.centerCoordinate.latitude),\(map.centerCoordinate.longitude), pochylenie=\(map.camera.pitch), tryb=\(settings.cameraMode), Metal=\(modelLayer?.isReady == true), oszczędzanie=\(ProcessInfo.processInfo.isLowPowerModeEnabled), temperatura=\(ProcessInfo.processInfo.thermalState.rawValue), budynki: \(buildingModels.diagnostics)")
            }
        }
        #endif
    }

    /// Used only before the first native drawing context arrives (or during a
    /// rapid camera change). It still accounts for height, unlike the old ground patch.
    private func approximateBounds(at coordinate: CLLocationCoordinate2D, model: MapStreetFurnitureGeometry.Bounds,
                                   on map: MLNMapView) -> CGRect {
        let point = map.convert(coordinate, toPointTo: map)
        let scale = 1 / max(0.001, map.metersPerPoint(atLatitude: coordinate.latitude))
        let pitch = Double(map.camera.pitch) * .pi / 180
        let heading = Double(map.camera.heading) * .pi / 180
        let width = model.maximum.x - model.minimum.x, depth = model.maximum.y - model.minimum.y
        let horizontal = (abs(cos(heading)) * width + abs(sin(heading)) * depth) * scale
        let ground = (abs(sin(heading)) * width + abs(cos(heading)) * depth) * scale * cos(pitch)
        let vertical = model.maximum.z * scale * sin(pitch)
        return CGRect(x: point.x - horizontal / 2, y: point.y - ground / 2 - vertical,
                      width: horizontal, height: ground + vertical)
    }

    private func distanceFromRoute(_ point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var result = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            result = min(result, hypot(point.x - a.x - t * dx, point.y - a.y - t * dy))
        }
        return result
    }

}
#endif
