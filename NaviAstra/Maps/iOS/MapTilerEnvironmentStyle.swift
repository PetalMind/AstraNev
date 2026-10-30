#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// Planet v4 augments OpenFreeMap. It never replaces DetailedRoad's lane geometry.
@MainActor
enum MapTilerEnvironmentStyle {
    private static let prefix = MapEnvironmentStyle.prefix + "planet-"
    static let sourceID = prefix + "source"
    static let buildingsSourceID = prefix + "buildings-source"
    static let buildingLayerID = prefix + "building-3d"
    static let fallbackBuildingID = prefix + "building-fallback-3d"
    static let fallbackFootprintID = prefix + "building-fallback-footprint"

    static let fallbackSourceID = prefix + "building-fallback-source"

    static var configuredURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DetailedEnvironmentTileJSONURL") as? String,
              let components = URLComponents(string: raw), components.scheme == "https",
              components.host == "api.maptiler.com", components.path == "/tiles/v4/tiles.json",
              let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty, !key.contains("$("), let url = components.url else { return nil }
        return url
    }

    static var buildingsURL: URL? {
        guard let url = configuredURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/tiles/buildings/tiles.json"
        return components.url
    }

    static func configure(in style: MLNStyle) {
        guard let url = configuredURL, style.source(withIdentifier: sourceID) == nil else { return }
        let source = MLNVectorTileSource(identifier: sourceID, configurationURL: url)
        style.addSource(source)
        let ground = style.layers.first { ($0 as? MLNLineStyleLayer)?.sourceLayerIdentifier == "transportation" }
        // Parks and woods may include a lake without a hole in their polygon.
        // Water polygons and river lines must paint over that land.
        let landscape = style.layers.first {
            guard $0 is MLNFillStyleLayer || $0 is MLNLineStyleLayer,
                  let layer = $0 as? MLNVectorStyleLayer else { return false }
            return layer.sourceLayerIdentifier == "water" || layer.sourceLayerIdentifier == "waterway"
        } ?? ground
        let bridge = style.layers.first { $0 is MLNLineStyleLayer && $0.identifier.hasPrefix("bridge_") }
        let building = style.layers.first { ($0 as? MLNFillStyleLayer)?.sourceLayerIdentifier == "building" }
        // Landscape below water; urban surfaces below roads; markings below bridges.
        for (id, sourceLayer, minZoom): (String, String, Float) in [
            ("forest", "forest", 0), ("wood", "wood", 10), ("grass", "grass", 12), ("leisure", "leisure", 16),
            ("parking", "parking", 15), ("pedestrian", "pedestrian", 16),
            ("parking-space-fill", "parking", 17)
        ] {
            let fill = MLNFillStyleLayer(identifier: prefix + id, source: source)
            fill.sourceLayerIdentifier = sourceLayer
            fill.minimumZoomLevel = minZoom
            // `forest` is only delivered through native z9; z10+ uses `wood`.
            if id == "forest" { fill.maximumZoomLevel = 10 }
            if id == "parking" || id == "parking-space-fill" {
                fill.predicate = parkingPredicate(spaces: id == "parking-space-fill")
            } else if id == "pedestrian" {
                fill.predicate = pathwayPredicate(bridge: false)
            }
            fill.fillAntialiased = NSExpression(forConstantValue: true)
            let anchor = ["forest", "wood", "grass", "leisure"].contains(id) ? landscape : ground
            insert(fill, into: style, below: anchor)
        }
        let forestPattern = MLNFillStyleLayer(identifier: prefix + "wood-pattern", source: source)
        forestPattern.sourceLayerIdentifier = "wood"
        forestPattern.minimumZoomLevel = 16
        if let wood = style.layer(withIdentifier: prefix + "wood") {
            style.insertLayer(forestPattern, above: wood)
        } else { insert(forestPattern, into: style, below: landscape) }
        if let grass = style.layer(withIdentifier: prefix + "grass") {
            let pattern = MLNFillStyleLayer(identifier: prefix + "grass-pattern", source: source)
            pattern.sourceLayerIdentifier = "grass"
            pattern.predicate = NSPredicate(format: "class IN %@", ["grass", "grassland", "meadow", "wet_meadow"])
            pattern.minimumZoomLevel = 15
            style.insertLayer(pattern, above: grass)
        }
        for (id, spaces, minZoom): (String, Bool, Float) in [("parking-edge", false, 15), ("parking-space-edge", true, 17)] {
            let line = MLNLineStyleLayer(identifier: prefix + id, source: source)
            line.sourceLayerIdentifier = "parking"
            line.minimumZoomLevel = minZoom
            line.predicate = parkingPredicate(spaces: spaces)
            insert(line, into: style, below: ground)
        }
        // Ground paths belong below carriageways. This also clips native fallback
        // ribbons at the road edge while detailed surfaces are loading or unavailable.
        let groundApproach = MapEnvironmentStyle.groundRoadAnchor(in: style) ?? ground
        for elevated in [false, true] {
            let anchor = elevated ? building : groundApproach
            for part in ["edge", "surface", "steps"] {
                let line = MLNLineStyleLayer(identifier: prefix + "path-" + (elevated ? "bridge-" : "ground-") + part, source: source)
                line.sourceLayerIdentifier = "pathway"
                line.minimumZoomLevel = part == "steps" ? 18 : 15
                var filters = [pathwayPredicate(bridge: elevated)]
                if part == "steps" { filters.append(NSPredicate(format: "class == %@", "steps")) }
                line.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: filters)
                line.lineJoin = NSExpression(forConstantValue: "round")
                line.lineCap = NSExpression(forConstantValue: "round")
                if part == "steps" { line.lineDashPattern = NSExpression(forConstantValue: [0.35, 1.3]) }
                insert(line, into: style, below: anchor)
            }
        }
        let elevatedArea = MLNFillStyleLayer(identifier: prefix + "pedestrian-bridge", source: source)
        elevatedArea.sourceLayerIdentifier = "pedestrian"
        elevatedArea.minimumZoomLevel = 16
        elevatedArea.predicate = pathwayPredicate(bridge: true)
        insert(elevatedArea, into: style, below: building)
        let paving = MLNFillStyleLayer(identifier: prefix + "pedestrian-pattern", source: source)
        paving.sourceLayerIdentifier = "pedestrian"
        paving.minimumZoomLevel = 17
        paving.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            pathwayPredicate(bridge: false), NSPredicate(format: "paved == true")
        ])
        insert(paving, into: style, below: ground)
        let kerb = MLNLineStyleLayer(identifier: prefix + "kerb-line", source: source)
        kerb.sourceLayerIdentifier = "traffic_control"
        kerb.minimumZoomLevel = 18
        kerb.predicate = NSPredicate(format: "class == %@ AND subclass == %@", "protection", "kerb")
        insert(kerb, into: style, below: bridge ?? building)
        for (id, category, subclasses): (String, String, [String]) in [
            ("guard-rail", "protection", ["guard_rail", "handrail"]),
            ("wall", "barrier", ["wall", "city_wall", "retaining_wall"]),
            ("fence", "barrier", ["fence"]),
            ("traffic-calming", "traffic_calming", [])
        ] {
            let line = MLNLineStyleLayer(identifier: prefix + id, source: source)
            line.sourceLayerIdentifier = "traffic_control"
            line.minimumZoomLevel = 18
            line.predicate = subclasses.isEmpty ? NSPredicate(format: "class == %@", category)
                : NSPredicate(format: "class == %@ AND subclass IN %@", category, subclasses)
            line.lineJoin = NSExpression(forConstantValue: "round")
            if id == "fence" { line.lineDashPattern = NSExpression(forConstantValue: [1, 1.5]) }
            insert(line, into: style, below: bridge ?? building)
        }
        let trees = MLNCircleStyleLayer(identifier: prefix + "trees", source: source)
        trees.sourceLayerIdentifier = "tree"
        trees.minimumZoomLevel = 15
        insert(trees, into: style, below: landscape)
        let kerbPoints = MLNCircleStyleLayer(identifier: prefix + "kerb-points", source: source)
        kerbPoints.sourceLayerIdentifier = "street_furniture"
        kerbPoints.minimumZoomLevel = 18
        kerbPoints.predicate = kerb.predicate
        insert(kerbPoints, into: style, below: bridge ?? building)
        installRailway(in: style, source: source, ground: bridge ?? building, elevated: building)
        let fallback = MLNShapeSource(identifier: fallbackSourceID, shape: nil, options: [.maximumZoomLevel: 18, .buffer: 128])
        style.addSource(fallback)
        installBuildings(in: style, source: fallback, anchor: building, fallback: true)
        let buildingProbe = MLNFillStyleLayer(identifier: prefix + "building-load", source: source)
        buildingProbe.sourceLayerIdentifier = "building"
        buildingProbe.minimumZoomLevel = 15
        buildingProbe.fillOpacity = NSExpression(forConstantValue: 0)
        insert(buildingProbe, into: style, below: building)
        if let url = buildingsURL {
            let buildings = MLNVectorTileSource(identifier: buildingsSourceID, configurationURL: url)
            style.addSource(buildings)
            installBuildings(in: style, source: buildings, anchor: building)
        }
        // Do not retain the less detailed base forest beneath the precise wood boundary,
        // or draw the same buildings and railway detail from two different tilesets.
        for layer in style.layers {
            guard let vector = layer as? MLNVectorStyleLayer, vector.sourceIdentifier == "openmaptiles" else { continue }
            if layer.identifier == "landcover_wood" || layer.identifier.hasPrefix("naviastra-forest-tree-pattern") {
                layer.isVisible = false
            } else if layer.identifier == "naviastra-low-vegetation-grass" {
                // Use the precise grass polygons for texture when Planet is enabled.
                layer.isVisible = false
            } else if vector.sourceLayerIdentifier == "building" {
                layer.maximumZoomLevel = 15
            } else if vector.sourceLayerIdentifier == "transportation",
                      layer.identifier.contains("path") || layer.identifier.contains("pedestrian")
                        || layer.identifier == MapEnvironmentStyle.prefix + "paving" {
                // Planet supplies these paths/areas from z15. Retaining Liberty's
                // copy creates offset edges and old rounded caps over the new joins.
                layer.maximumZoomLevel = min(layer.maximumZoomLevel, 15)
            } else if vector.sourceLayerIdentifier == "transportation", layer.identifier == "road_area_pattern" {
                // This base layer also contains vehicle-road polygons; retain those.
                vector.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    vector.predicate,
                    NSPredicate(format: "NOT (class IN %@)", ["path", "pedestrian"])
                ].compactMap { $0 })
            } else if vector.sourceLayerIdentifier == "transportation", layer.identifier.contains("rail") {
                // Keep existing subway / monorail / funicular presentation; these
                // are outside the railway classes added from Planet in this change.
                if let original = layer as? MLNLineStyleLayer,
                   original.identifier.contains("hatching") || original.identifier.hasPrefix(MapEnvironmentStyle.prefix),
                   let baseSource = style.source(withIdentifier: "openmaptiles") {
                    let fallback = MLNLineStyleLayer(identifier: MapEnvironmentStyle.prefix + "fallback-" + original.identifier, source: baseSource)
                    fallback.sourceLayerIdentifier = "transportation"
                    fallback.minimumZoomLevel = 17
                    fallback.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        original.predicate,
                        NSPredicate(format: "subclass IN %@", ["subway", "monorail", "funicular"])
                    ].compactMap { $0 })
                    fallback.lineOffset = original.lineOffset
                    fallback.lineWidth = original.lineWidth
                    fallback.lineJoin = original.lineJoin
                    fallback.lineCap = original.lineCap
                    style.insertLayer(fallback, above: original)
                }
                layer.maximumZoomLevel = 17
            }
        }
        for dark in [false, true] {
            style.setImage(MapCrosswalkAppearance.image(dark: dark), forName: imageName("crossing", dark: dark))
            style.setImage(accessibleParkingIcon(dark: dark), forName: imageName("parking-space-disabled", dark: dark))
            for (kind, symbol) in [("entrance", "door.left.hand.open"),
                                   ("bench", "chair.lounge.fill"), ("street_lamp", "lightbulb.fill"),
                                   ("fountain", "drop.fill"), ("traffic_signals", "stoplights.fill"),
                                   ("bollard", "smallcircle.filled.circle")] {
                style.setImage(icon(symbol: symbol, dark: dark), forName: imageName(kind, dark: dark))
            }
        }
        let accessibleParking = MLNSymbolStyleLayer(identifier: prefix + "parking-space-disabled-symbol", source: source)
        accessibleParking.sourceLayerIdentifier = "parking"
        accessibleParking.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            parkingPredicate(spaces: true), NSPredicate(format: "parking_space == %@", "disabled")
        ])
        accessibleParking.minimumZoomLevel = 18.5
        accessibleParking.symbolPlacement = NSExpression(forConstantValue: "point")
        accessibleParking.iconAnchor = NSExpression(forConstantValue: "center")
        accessibleParking.iconRotationAlignment = NSExpression(forConstantValue: "map")
        accessibleParking.iconPitchAlignment = NSExpression(forConstantValue: "map")
        // Surface markings remain visible independently of POI labels and their collisions.
        accessibleParking.iconAllowsOverlap = NSExpression(forConstantValue: true)
        accessibleParking.iconIgnoresPlacement = NSExpression(forConstantValue: true)
        insert(accessibleParking, into: style, below: bridge ?? building)
        let crosswalks = MLNShapeSource(identifier: MapCrosswalkRenderer.sourceID, shape: nil, options: nil)
        style.addSource(crosswalks)
        // Load actual road/crossing geometry for orientation, without drawing a second copy.
        let crossingProbe = MLNCircleStyleLayer(identifier: prefix + "crossing-geometry", source: source)
        crossingProbe.sourceLayerIdentifier = "street_furniture"
        crossingProbe.minimumZoomLevel = 17
        crossingProbe.predicate = NSPredicate(format: "class == %@ AND subclass == %@", "street", "crossing")
        crossingProbe.circleRadius = NSExpression(forConstantValue: 1)
        crossingProbe.circleOpacity = NSExpression(forConstantValue: 0)
        crossingProbe.circleStrokeOpacity = NSExpression(forConstantValue: 0)
        style.addLayer(crossingProbe)
        let roadProbe = MLNLineStyleLayer(identifier: prefix + "crossing-road-geometry", source: source)
        roadProbe.sourceLayerIdentifier = "road"
        roadProbe.minimumZoomLevel = 17
        roadProbe.lineOpacity = NSExpression(forConstantValue: 0)
        style.addLayer(roadProbe)
        for kind in ["crossing", "entrance", "bench", "street_lamp", "fountain", "traffic_signals", "bollard"] {
            let symbol = MLNSymbolStyleLayer(identifier: prefix + "point-" + kind,
                source: kind == "crossing" ? crosswalks : source)
            if kind != "crossing" { symbol.sourceLayerIdentifier = "street_furniture" }
            let category = kind == "entrance" ? "access_control" : (kind == "bollard" ? "protection" : "street")
            if kind != "crossing" {
                symbol.predicate = NSPredicate(format: "class == %@ AND subclass == %@", category, kind)
            }
            symbol.minimumZoomLevel = kind == "crossing" ? 17
                : (["entrance", "traffic_signals"].contains(kind) ? 18 : 18.5)
            symbol.iconAllowsOverlap = NSExpression(forConstantValue: false)
            symbol.iconIgnoresPlacement = NSExpression(forConstantValue: false)
            symbol.iconRotationAlignment = NSExpression(forConstantValue: "map")
            symbol.iconPitchAlignment = NSExpression(forConstantValue: "map")
            if kind == "crossing" {
                MapCrosswalkAppearance.configure(symbol)
                // Paint over road surfaces, under buildings, POI and navigation overlays.
                let paintAnchor = style.layers.first {
                    ($0 as? MLNVectorStyleLayer)?.sourceLayerIdentifier == "building"
                } ?? style.layers.first { $0 is MLNSymbolStyleLayer }
                insert(symbol, into: style, below: paintAnchor)
                continue
            }
            // Append after buildings and base labels, before route overlays are installed.
            style.addLayer(symbol)
        }
    }

    static func apply(to style: MLNStyle, settings: MapSettings, dark: Bool) {
        let driving = settings.context == .driving
        let navigating = settings.context.isNavigating
        let quiet = driving ? 0.72 : 1.0
        let cycleFocus = settings.context == .cycling
        let pavedPathColor: [Any] = ["match", ["get", "class"],
            "cycleway", rgb(cycleFocus ? (dark ? 0x699594 : 0xB5D2C8) : (dark ? 0x333B3B : 0xE1E9DE)),
            "pedestrian", rgb(dark ? 0x363538 : 0xEDE8DF), rgb(dark ? 0x313238 : 0xF4F1EC)]
        // `paved` distinguishes unpaved paths, without claiming a specific material.
        let pathColor: [Any] = ["case", ["==", ["get", "paved"], false],
            rgb(dark ? 0x3B3932 : 0xE5DFD0), pavedPathColor]
        for layer in style.layers where [sourceID, buildingsSourceID, fallbackSourceID, MapCrosswalkRenderer.sourceID]
            .contains((layer as? MLNVectorStyleLayer)?.sourceIdentifier ?? "") {
            let id = layer.identifier
            if id.hasPrefix(MapTerrainTextureStyle.prefix) { continue }
            if MapStreetFurnitureRenderer.isSourceProbe(id) || id == prefix + "building-load" || id.hasPrefix("naviastra-poi-load-") || id == prefix + "crossing-geometry"
                || id == prefix + "crossing-road-geometry" { continue }
            if let fill = layer as? MLNFillStyleLayer {
                if id == prefix + "wood" || id == prefix + "forest" {
                    fill.fillColor = color(dark ? 0x21362B : 0xB9D3B2)
                    fill.fillOpacity = NSExpression(forConstantValue: 1)
                } else if id == prefix + "wood-pattern" {
                    fill.fillPattern = NSExpression(forConstantValue: "naviastra-forest-" + (dark ? "dark" : "light") + "-unknown")
                    fill.fillOpacity = fade(16, 17, maximum: 0.10 * quiet)
                } else if id == prefix + "grass-pattern" {
                    let suffix = dark ? "dark" : "light"
                    fill.fillPattern = NSExpression(mglJSONObject: ["match", ["get", "class"],
                        "wet_meadow", "naviastra-low-vegetation-sprite-wetland-" + suffix,
                        "naviastra-low-vegetation-sprite-grass-" + suffix])
                    fill.fillOpacity = MapTerrainTextureStyle.grassOpacity(navigating: navigating)
                } else if id == prefix + "grass" {
                    fill.fillColor = NSExpression(mglJSONObject: ["match", ["get", "class"],
                        ["park", "garden"], rgb(dark ? 0x293E32 : 0xD3E3C6),
                        "wet_meadow", rgb(dark ? 0x2B4140 : 0xC6DCD2),
                        ["allotments", "golf_course", "heath", "fell", "shrubbery", "tundra"], rgb(dark ? 0x304334 : 0xD6E3C7),
                        rgb(dark ? 0x344638 : 0xE0E9D2)])
                    fill.fillOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                        12, ["match", ["get", "class"], ["park", "garden"], 1, 0], 15, 1])
                } else if id == prefix + "leisure" {
                    fill.fillColor = color(dark ? 0x33443C : 0xD8E2D1)
                    fill.fillOpacity = fade(16, 17, maximum: 0.8 * quiet)
                } else if id == prefix + "parking" || id == prefix + "parking-space-fill" {
                    fill.fillColor = NSExpression(mglJSONObject: ["match", ["get", "parking_space"],
                        "disabled", rgb(dark ? 0x3B535E : 0xD5E3EA),
                        ["charging", "eletric_vehicle"], rgb(dark ? 0x354D43 : 0xD8E6D9),
                        rgb(dark ? 0x303238 : 0xE3E2DE)])
                    let start = Double(fill.minimumZoomLevel)
                    fill.fillOpacity = fade(start, start + 0.5, maximum: id.hasSuffix("space-fill") ? 0.65 * quiet : 0.92)
                } else if id == prefix + "building-footprint" || id == fallbackFootprintID {
                    fill.fillColor = MapBuildingAppearance.color(dark: dark, heightKey: "height")
                    fill.fillOutlineColor = MapBuildingAppearance.outline(dark: dark)
                    fill.fillOpacity = NSExpression(forConstantValue: settings.context.isNavigating ? 0.50 : 0.88)
                } else if id == prefix + "pedestrian-pattern" {
                    fill.fillPattern = NSExpression(forConstantValue: MapEnvironmentStyle.prefix + "paving-" + (dark ? "night" : "day"))
                    fill.fillOpacity = fade(17, 18, maximum: driving ? 0.04 : 0.08)
                } else {
                    fill.fillColor = NSExpression(mglJSONObject: pathColor)
                    fill.fillOpacity = fade(16, 17, maximum: quiet)
                }
            } else if let extrusion = layer as? MLNFillExtrusionStyleLayer {
                extrusion.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                extrusion.fillExtrusionColor = MapBuildingAppearance.color(dark: dark, heightKey: "height")
                MapBuildingAppearance.applySolidRendering(to: extrusion)
            } else if let line = layer as? MLNLineStyleLayer {
                if line.sourceLayerIdentifier == "railway" {
                    applyRailway(line, settings: settings, dark: dark)
                    continue
                }
                line.lineColor = color(dark ? 0x42434A : 0xD5D3CF)
                let start = Double(line.minimumZoomLevel)
                line.lineOpacity = fade(start, start + 0.5, maximum: quiet)
                if id.contains("path-") {
                    let edge = id.hasSuffix("edge")
                    line.lineColor = edge ? color(dark ? 0x42434A : 0xD5D3CF) : NSExpression(mglJSONObject: pathColor)
                    line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.6], ["zoom"],
                        15, edge ? 1.5 : 0.5, 16, edge ? 2.5 : 1.5, 17, edge ? 4.5 : 3.5, 18, edge ? 7 : 6, 20, edge ? 17 : 16])
                    if id.hasSuffix("steps") { line.lineColor = color(dark ? 0x68686B : 0xBCB9B2) }
                } else {
                    line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 15, 0.5, 18, 0.9, 20, 1.4])
                    if id.hasSuffix("kerb-line") {
                        line.lineColor = NSExpression(mglJSONObject: ["case", ["==", ["get", "lowered"], true],
                            rgb(dark ? 0x525459 : 0xDEDAD2), rgb(dark ? 0x77787B : 0xC5C2BB)])
                    } else if line.sourceLayerIdentifier == "traffic_control" {
                        line.lineColor = color(dark ? 0x727579 : 0xA7A9A5)
                        let wall = id.hasSuffix("wall")
                        line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                            18, wall ? 1.4 : 0.8, 20, wall ? 2.5 : 1.5])
                        line.lineOpacity = fade(18, 18.5, maximum: (id.hasSuffix("traffic-calming") ? 0.5 : 0.7) * quiet)
                    }
                }
            } else if let circle = layer as? MLNCircleStyleLayer {
                let tree = id.hasSuffix("trees")
                circle.circleColor = color(tree ? (dark ? 0x56725A : 0xA6C398) : (dark ? 0x77787B : 0xC5C2BB))
                circle.circleRadius = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                    15, tree ? 1 : 1.5, 17, tree ? 2 : 1.5, 20, tree ? 5 : 2.5])
                circle.circleOpacity = fade(tree ? 15 : 18, tree ? 16 : 18.5, maximum: (tree ? 0.45 : 0.7) * quiet)
                if tree, MapStreetFurnitureRenderer.replacesTrees(in: style, settings: settings) {
                    circle.maximumZoomLevel = Float(MapStreetFurnitureRenderer.minimumZoom)
                    circle.isVisible = true
                } else if tree {
                    circle.maximumZoomLevel = 24
                    circle.isVisible = true
                }
                circle.circleStrokeWidth = NSExpression(forConstantValue: tree ? 0.5 : 0)
                circle.circleStrokeColor = color(dark ? 0x405F48 : 0x8FAC82)
                circle.circlePitchAlignment = NSExpression(forConstantValue: "map")
                circle.circleScaleAlignment = NSExpression(forConstantValue: "map")
            } else if let symbol = layer as? MLNSymbolStyleLayer {
                if id == prefix + "parking-space-disabled-symbol" {
                    symbol.iconImageName = NSExpression(forConstantValue: imageName("parking-space-disabled", dark: dark))
                    symbol.iconScale = NSExpression(mglJSONObject: [
                        "interpolate", ["exponential", 2], ["zoom"],
                        18.5, 0.4, 19, 0.65, 20, 1.2, 22, 3.8
                    ])
                    symbol.iconOpacity = fade(18.5, 19, maximum: 0.95)
                    symbol.isVisible = true
                    continue
                }
                let kind = String(id.dropFirst((prefix + "point-").count))
                symbol.iconImageName = NSExpression(forConstantValue: imageName(kind, dark: dark))
                if kind == "crossing" {
                    MapCrosswalkAppearance.apply(to: symbol)
                    continue
                }
                symbol.iconScale = NSExpression(forConstantValue: 0.5)
                let start = Double(symbol.minimumZoomLevel)
                symbol.iconOpacity = fade(start, start + 0.5, maximum: 0.8 * quiet)
                let replacedByModel = MapStreetFurnitureRenderer.replacesSymbol(kind, in: style, settings: settings)
                symbol.isVisible = settings.overlays.poi && !replacedByModel

            }
        }
    }

    static func isBuildingLayer(_ layer: MLNVectorStyleLayer) -> Bool {
        layer.sourceLayerIdentifier == "building" || layer.identifier == fallbackBuildingID
            || layer.identifier == fallbackFootprintID
    }

    private static func installBuildings(in style: MLNStyle, source: MLNSource, anchor: MLNStyleLayer?, fallback: Bool = false) {
        let footprint = MLNFillStyleLayer(identifier: fallback ? fallbackFootprintID : prefix + "building-footprint", source: source)
        footprint.sourceLayerIdentifier = fallback ? nil : "building"
        footprint.minimumZoomLevel = 15
        footprint.predicate = NSPredicate(format: "underground == nil OR underground != true")
        footprint.fillAntialiased = NSExpression(forConstantValue: true)
        insert(footprint, into: style, below: anchor)
        let building = MLNFillExtrusionStyleLayer(identifier: fallback ? fallbackBuildingID : buildingLayerID, source: source)
        building.sourceLayerIdentifier = fallback ? nil : "building"
        building.minimumZoomLevel = Float(MapEnvironmentModelPolicy.minimumZoom)
        building.predicate = NSPredicate(format: "(underground == nil OR underground != true) AND height > 0 AND (height_min == nil OR height_min < height)")
        building.fillExtrusionHeight = NSExpression(mglJSONObject: ["coalesce", ["get", "height"], 0])
        building.fillExtrusionBase = NSExpression(mglJSONObject: ["coalesce", ["get", "height_min"], 0])
        building.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
        building.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: MapBuildingAppearance.cornerDistance)
        style.insertLayer(building, above: footprint)
        guard !fallback else { return }
        let entrances = MLNCircleStyleLayer(identifier: prefix + "building-entrances", source: source)
        entrances.sourceLayerIdentifier = "building_entrance"
        entrances.minimumZoomLevel = 18
        entrances.circleRadius = NSExpression(forConstantValue: 2.5)
        style.insertLayer(entrances, above: building)
    }

    private static func installRailway(in style: MLNStyle, source: MLNSource,
                                       ground: MLNStyleLayer?, elevated: MLNStyleLayer?) {
        for level in ["ground", "bridge", "tunnel"] {
            let elevation = level == "ground"
                ? NSPredicate(format: "brunnel == nil OR NOT (brunnel IN %@)", ["bridge", "tunnel"])
                : NSPredicate(format: "brunnel == %@", level)
            let mappedRail = NSCompoundPredicate(andPredicateWithSubpredicates: [elevation,
                NSPredicate(format: "class IN %@ AND (construction == nil OR construction != true)",
                            ["rail", "tram", "light_rail", "narrow_gauge", "preserved", "disused", "abandoned"])])
            let anchor = level == "bridge" ? elevated : ground
            for part in (level == "tunnel" ? ["center"] : ["center", "sleepers", "left", "right"]) {
                let line = MLNLineStyleLayer(identifier: prefix + "railway-" + level + "-" + part, source: source)
                line.sourceLayerIdentifier = "railway"
                line.minimumZoomLevel = 17
                line.predicate = level == "tunnel" ? mappedRail : NSCompoundPredicate(andPredicateWithSubpredicates: [
                    mappedRail, NSPredicate(format: part == "center" ? "class == %@" : "class != %@", "abandoned")
                ])
                line.lineJoin = NSExpression(forConstantValue: "round")
                if part == "sleepers" {
                    line.lineDashPattern = NSExpression(forConstantValue: [0.25, 2.5])
                } else if level == "tunnel" || part == "center" {
                    line.lineDashPattern = NSExpression(forConstantValue: [2, 2])
                }
                if part == "left" || part == "right" {
                    let side = part == "left" ? -1.0 : 1.0
                    line.lineOffset = NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.4], ["zoom"],
                        17, side, 20, side * 3.5])
                }
                insert(line, into: style, below: anchor)
            }
        }
    }

    private static func applyRailway(_ line: MLNLineStyleLayer, settings: MapSettings, dark: Bool) {
        let strength = settings.overlays.transit || settings.context == .transit ? 0.8 : 0.48
        let tunnel = line.identifier.contains("-tunnel-")
        let sleeper = line.identifier.hasSuffix("-sleepers")
        let center = line.identifier.hasSuffix("-center")
        line.lineColor = color(dark ? 0x687279 : 0xA5AAA9)
        line.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.4], ["zoom"],
            17, sleeper ? 3 : 0.6, 20, sleeper ? 8 : 1.1])
        let activeOpacity: Any = center && !tunnel ? 0 : strength * (tunnel ? 0.55 : 1)
        line.lineOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 17, 0, 17.7,
            ["match", ["get", "class"], "abandoned", strength * 0.35,
             "disused", center && !tunnel ? 0 : strength * 0.5, activeOpacity]])
    }

    private static func pathwayPredicate(bridge: Bool) -> NSPredicate {
        let elevation = bridge ? NSPredicate(format: "brunnel == %@", "bridge")
            : NSPredicate(format: "(brunnel == nil OR NOT (brunnel IN %@)) AND (layer == nil OR layer >= 0)", ["bridge", "tunnel"])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [elevation,
            NSPredicate(format: "(indoor == nil OR indoor != true) AND (construction == nil OR construction != true) AND (level == nil OR level >= 0)")])
    }
    private static func parkingPredicate(spaces: Bool) -> NSPredicate {
        NSPredicate(format: "subclass == %@ AND (parking == nil OR NOT (parking IN %@))", spaces ? "parking_space" : "parking",
                    ["underground", "rooftop", "multi-storey", "garage", "garage_boxes"])
    }
    private static func insert(_ layer: MLNStyleLayer, into style: MLNStyle, below anchor: MLNStyleLayer?) {
        if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
    }
    private static func fade(_ start: Double, _ end: Double, maximum: Double) -> NSExpression {
        NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], start, 0, end, maximum])
    }
    private static func color(_ value: UInt32) -> NSExpression { NSExpression(forConstantValue: UIColor(naviHex: value)) }
    // JSON colors must have an explicit color type; a bare string stays NSString in NSExpression.
    private static func rgb(_ value: UInt32) -> [Any] {
        ["rgb", (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }
    static func imageName(_ kind: String, dark: Bool) -> String { prefix + kind + (dark ? "-night" : "-day") }
    private static func accessibleParkingIcon(dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIImage(systemName: "figure.roll", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { _ in
            image?.withTintColor(UIColor(naviHex: dark ? 0xC2DFEE : 0x356782), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 2, y: 2, width: 20, height: 20))
        }
    }
    private static func icon(symbol: String, dark: Bool) -> UIImage {
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            image?.withTintColor(UIColor(naviHex: dark ? 0x989D9E : 0x8A8D89), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        }
    }
}
#endif
