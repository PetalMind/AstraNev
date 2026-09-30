#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// NaviAstra's visual layer on top of the OpenFreeMap / OpenMapTiles schema.
/// No fabricated POI, heights, traffic, or elevation data are introduced here.
final class NaviAstraMapStyle {
    private var lastKey = ""
    private var originalPredicates: [String: NSPredicate] = [:]
    private var poiLayerIDs: [String] = []
    private var poiCategories: [MapPOICategory] = []
    private var poiDensity: Int?
    private var configured = false

    func reset() {
        lastKey = ""
        originalPredicates.removeAll()
        poiLayerIDs.removeAll()
        poiCategories = []
        poiDensity = nil
        configured = false
    }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool,
               activelyNavigating: Bool, zoom: Double) {
        if !configured {
            configure(style)
            configured = true
        }
        let density = Self.densityLevel(for: zoom)
        let categories = settings.visiblePOICategories.sorted { $0.rawValue < $1.rawValue }
        let key = "\(dark)-\(activelyNavigating)-\(settings.context)-\(categories.map(\.rawValue))-\(settings.overlays.buildings3D)-\(settings.cameraMode)-\(settings.overlays.transit)"
        guard key != lastKey else {
            updatePOIDensity(to: style, zoom: zoom)
            return
        }
        lastKey = key
        poiCategories = categories
        let navigating = settings.context.isNavigating
        let transitionDuration = navigating ? 0.16 : 0.4
        style.transition = MLNTransition(duration: transitionDuration, delay: 0)
        let light = style.light
        let lightPosition = MLNSphericalPositionMake(1.15, dark ? 220 : 225, dark ? 55 : 50)
        light.anchor = NSExpression(forConstantValue: "map")
        light.position = NSExpression(forConstantValue: NSValue(mlnSphericalPosition: lightPosition))
        light.intensity = NSExpression(forConstantValue: dark ? 0.34 : 0.56)
        light.color = NSExpression(forConstantValue: color(dark ? NaviAstraColorPalette.mapLabelNight : 0xF2F5F8))
        light.positionTransition = MLNTransition(duration: transitionDuration, delay: 0)
        light.intensityTransition = MLNTransition(duration: transitionDuration, delay: 0)
        light.colorTransition = MLNTransition(duration: transitionDuration, delay: 0)
        style.light = light
        let background = color(dark ? NaviAstraColorPalette.mapBackgroundNight : NaviAstraColorPalette.mapBackgroundDay)
        let text = color(dark ? NaviAstraColorPalette.mapLabelNight : NaviAstraColorPalette.mapLabelDay)
        let muted = color(dark ? NaviAstraColorPalette.routeAlternativeNight : NaviAstraColorPalette.routeAlternativeDay)
        let water = color(dark ? NaviAstraColorPalette.mapWaterNight : NaviAstraColorPalette.mapWaterDay)
        let majorRoad = color(dark
            ? (activelyNavigating ? NaviAstraColorPalette.mapMainRoadNightNavigation
                                  : NaviAstraColorPalette.mapMainRoadNightExploration)
            : 0xFFFFFF)
        let minorRoad = color(dark ? NaviAstraColorPalette.mapLocalRoadNight : 0xFFFFFF)
        let roadOutline = color(dark ? NaviAstraColorPalette.mapBackgroundNight
                                     : NaviAstraColorPalette.mapMainRoadOutlineDay)

        for layer in style.layers {
            let id = layer.identifier
            if let layer = layer as? MLNBackgroundStyleLayer {
                layer.backgroundColor = NSExpression(forConstantValue: background)
            }
            // The low-zoom raster would otherwise retain its daytime colors at night.
            if id == "natural_earth" { layer.isVisible = !dark }
            if let layer = layer as? MLNFillStyleLayer {
                if id == "naviastra-forest-tree-pattern" {
                    layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: dark, dense: false))
                    continue
                }
                if id == "naviastra-forest-tree-pattern-dense" {
                    layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: dark, dense: true))
                    continue
                }
                if id == "naviastra-water-wave-pattern" {
                    layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: dark, dense: false))
                    continue
                }
                if id == "naviastra-water-wave-pattern-dense" {
                    layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: dark, dense: true))
                    continue
                }
                let source = layer.sourceLayerIdentifier ?? ""
                let fill: UIColor
                switch source {
                case "water":
                    layer.fillColor = waterColorExpression(dark: dark)
                    layer.fillOpacity = NSExpression(mglJSONObject: [
                        "case", ["==", ["get", "intermittent"], 1], 0.82, 1
                    ])
                    continue
                case "waterway": fill = water
                case "park": fill = color(dark ? NaviAstraColorPalette.mapParkNight : NaviAstraColorPalette.mapParkDay)
                case "landcover":
                    layer.fillColor = landcoverColorExpression(dark: dark)
                    continue
                case "landuse": fill = color(dark ? NaviAstraColorPalette.mapBuildingNight
                                                  : NaviAstraColorPalette.mapBuildingDay)
                case "building": fill = color(dark ? NaviAstraColorPalette.mapBuildingNight
                                                   : NaviAstraColorPalette.mapBuildingDay)
                case "aeroway": fill = color(dark ? 0x2B3C48 : 0xDCE4E8)
                default: continue
                }
                layer.fillColor = NSExpression(forConstantValue: fill)
                if source == "building" {
                    let neutralColor = dark ? "#1A2531" : "#E2E7EA"
                    layer.fillColor = buildingColorExpression(neutralColor: neutralColor)
                    layer.fillOpacity = NSExpression(forConstantValue: navigating ? 0.42 : 0.75)
                    layer.fillOutlineColor = NSExpression(forConstantValue: roadOutline)
                }
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer {
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = buildingColorExpression(neutralColor: dark ? "#1A2531" : "#E2E7EA")
                layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, navigating ? 0.08 : 0.12,
                    16, navigating ? 0.28 : 0.48,
                    17, navigating ? 0.42 : 0.72
                ])
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
                layer.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: 0.45)
            }
            if let layer = layer as? MLNLineStyleLayer {
                let source = layer.sourceLayerIdentifier ?? ""
                if source == "transportation" {
                    let casing = id.contains("casing")
                    let rail = id.contains("rail")
                    let main = id.contains("motorway") || id.contains("trunk") || id.contains("primary")
                    let path = id.contains("path") || id.contains("pedestrian")
                    let pathFocus = settings.context == .walking || settings.context == .cycling
                    let roadColor: UIColor = rail ? color(dark ? NaviAstraColorPalette.routeAlternativeNight
                                                               : NaviAstraColorPalette.routeAlternativeDay) :
                        (casing ? roadOutline :
                            (path && settings.context == .cycling
                                ? color(dark ? NaviAstraColorPalette.cyclingRouteNight
                                             : NaviAstraColorPalette.cyclingRouteDay)
                                : (main ? majorRoad : minorRoad)))
                    layer.lineColor = NSExpression(forConstantValue: roadColor)
                    layer.lineOpacity = NSExpression(forConstantValue: navigating && !main && !pathFocus ? 0.48 : 1.0)
                    if rail {
                        layer.lineOpacity = NSExpression(forConstantValue: settings.overlays.transit || settings.context == .transit ? 1.0 : 0.35)
                        layer.lineColor = NSExpression(forConstantValue: settings.overlays.transit
                            ? color(dark ? RouteColorPalette.alternativeDark : RouteColorPalette.alternativeLight)
                            : roadColor)
                    }
                } else if source == "waterway" {
                    layer.lineColor = NSExpression(forConstantValue: water)
                    layer.lineWidth = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"],
                        9, ["match", ["get", "class"], "river", 1.0, "canal", 0.8, 0.55],
                        16, ["match", ["get", "class"], "river", 3.0, "canal", 2.2, 1.25]
                    ])
                } else if source == "boundary" {
                    layer.lineColor = NSExpression(forConstantValue: muted)
                    layer.lineOpacity = NSExpression(forConstantValue: navigating ? 0.2 : 0.5)
                } else if source == "aeroway" {
                    layer.lineColor = NSExpression(forConstantValue: color(dark ? NaviAstraColorPalette.mapMainRoadNightExploration
                                                                              : NaviAstraColorPalette.mapMainRoadOutlineDay))
                } else if source == "park" {
                    layer.lineColor = NSExpression(forConstantValue: color(dark ? NaviAstraColorPalette.mapParkNight
                                                                              : NaviAstraColorPalette.mapParkDay))
                }
            }
            if let layer = layer as? MLNSymbolStyleLayer {
                let source = layer.sourceLayerIdentifier ?? ""
                layer.textColor = NSExpression(forConstantValue: text)
                layer.textHaloColor = NSExpression(forConstantValue: background)
                layer.textHaloWidth = NSExpression(forConstantValue: 1.2)
                if source == "poi" {
                    layer.iconImageName = poiIconExpression(dark: dark)
                    layer.predicate = poiPredicate(for: id, categories: categories, density: density)
                    layer.isVisible = !categories.isEmpty
                    layer.textOpacity = NSExpression(forConstantValue: 1)
                    layer.iconOpacity = NSExpression(forConstantValue: 1)
                } else if id.contains("highway-name-minor") || id.contains("highway-name-path") {
                    layer.textOpacity = NSExpression(forConstantValue: navigating && settings.context == .driving ? 0.4 : 1.0)
                } else if source == "place" {
                    layer.textOpacity = NSExpression(forConstantValue: navigating ? 0.6 : 1.0)
                }
            }
        }
        poiDensity = density
    }

    func updatePOIDensity(to style: MLNStyle, zoom: Double) {
        guard configured else { return }
        let density = Self.densityLevel(for: zoom)
        guard poiDensity != density else { return }
        for id in poiLayerIDs {
            guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
            layer.predicate = poiPredicate(for: id, categories: poiCategories, density: density)
        }
        poiDensity = density
    }

    private static func densityLevel(for zoom: Double) -> Int {
        zoom < 15 ? 0 : (zoom < 17 ? 1 : 2)
    }

    private func poiPredicate(for layerID: String, categories: [MapPOICategory], density: Int) -> NSPredicate {
        let values = categories.flatMap(\.tileValues)
        let categoryPredicate = values.isEmpty ? NSPredicate(value: false) :
            NSPredicate(format: "class IN %@ OR subclass IN %@", values, values)
        let providerTransitValues = MapPOICategory.transit.tileValues.filter { $0 != "airport" }
        let hideProviderTransitPredicate = NSPredicate(
            format: "NOT (class IN %@ OR subclass IN %@)", providerTransitValues, providerTransitValues)
        let rankLimit = density == 0 ? 3 : (density == 1 ? 19 : 1000)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            originalPredicates[layerID] ?? NSPredicate(value: true),
            categoryPredicate,
            hideProviderTransitPredicate,
            NSPredicate(format: "rank <= %d", rankLimit)
        ])
    }

    private func configure(_ style: MLNStyle) {
        for kind in PlacePOIMapMarkerKind.allCases {
            style.setImage(kind.makeMapStyleImage(dark: false), forName: poiImageName(kind, dark: false))
            style.setImage(kind.makeMapStyleImage(dark: true), forName: poiImageName(kind, dark: true))
        }
        for dark in [false, true] {
            style.setImage(forestTreePattern(dark: dark, dense: false),
                           forName: forestPatternName(dark: dark, dense: false))
            style.setImage(forestTreePattern(dark: dark, dense: true),
                           forName: forestPatternName(dark: dark, dense: true))
            style.setImage(waterWavePattern(dark: dark, dense: false),
                           forName: waterPatternName(dark: dark, dense: false))
            style.setImage(waterWavePattern(dark: dark, dense: true),
                           forName: waterPatternName(dark: dark, dense: true))
        }
        for layer in style.layers {
            if let layer = layer as? MLNSymbolStyleLayer, layer.sourceLayerIdentifier == "poi" {
                poiLayerIDs.append(layer.identifier)
                if let predicate = layer.predicate { originalPredicates[layer.identifier] = predicate }
                switch layer.identifier {
                case "poi_r1": layer.minimumZoomLevel = 12
                case "poi_r7": layer.minimumZoomLevel = 15
                case "poi_r20": layer.minimumZoomLevel = 17
                case "poi_transit": layer.minimumZoomLevel = 14
                default: break
                }
                layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
                layer.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 11, 17, 13])
                // Preserve collision detection: more available features must not mean overlapping labels.
                layer.textAllowsOverlap = NSExpression(forConstantValue: false)
                layer.iconAllowsOverlap = NSExpression(forConstantValue: false)
            }
            if let layer = layer as? MLNFillStyleLayer, layer.sourceLayerIdentifier == "building" {
                layer.maximumZoomLevel = 24 // Retain footprints when extrusion is disabled.
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer {
                layer.minimumZoomLevel = 15
                layer.predicate = NSPredicate(format: "hide_3d != true")
                layer.fillExtrusionHeight = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, 0, 16, ["*", ["coalesce", ["get", "render_height"], 0], 0.4],
                    17, ["coalesce", ["get", "render_height"], 0]
                ])
                layer.fillExtrusionBase = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    15, 0, 16, ["*", ["coalesce", ["get", "render_min_height"], 0], 0.4],
                    17, ["coalesce", ["get", "render_min_height"], 0]
                ])
            }
            if let layer = layer as? MLNLineStyleLayer, layer.sourceLayerIdentifier == "transportation",
               !layer.identifier.contains("rail"), !layer.identifier.contains("hatching") {
                let id = layer.identifier
                let major = id.contains("motorway") || id.contains("trunk") || id.contains("primary")
                let secondary = id.contains("secondary") || id.contains("tertiary")
                let path = id.contains("path") || id.contains("pedestrian")
                let casing: Double = id.contains("casing") ? 1.5 : 0
                let width: Double = major ? 11 : (secondary ? 8 : (path ? 3 : 5))
                layer.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["exponential", 1.4], ["zoom"],
                    10, (major ? 1.5 : 0.4) + casing * 0.3, 15, width * 0.45 + casing, 18, width + casing])
            }
        }
        installForestTreePatternLayers(in: style)
        installWaterWavePatternLayers(in: style)
        if style.layer(withIdentifier: "naviastra-house-numbers") == nil,
           let source = style.source(withIdentifier: "openmaptiles") {
            let numbers = MLNSymbolStyleLayer(identifier: "naviastra-house-numbers", source: source)
            numbers.sourceLayerIdentifier = "housenumber"
            numbers.minimumZoomLevel = 17
            numbers.text = NSExpression(forKeyPath: "housenumber")
            numbers.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            numbers.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 17, 10, 19, 13])
            numbers.textAllowsOverlap = NSExpression(forConstantValue: false)
            style.addLayer(numbers)
        }
    }

    private func installForestTreePatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let lastLandcoverFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "landcover" }) else { return }

        let forestFilter = NSPredicate(format: "subclass IN %@", ["forest", "wood"])
        let layers: [(String, Float, Float, Bool)] = [
            ("naviastra-forest-tree-pattern", 13, 15, false),
            ("naviastra-forest-tree-pattern-dense", 15, 24, true)
        ]
        for (identifier, minimumZoom, maximumZoom, dense) in layers
            where style.layer(withIdentifier: identifier) == nil {
            let layer = MLNFillStyleLayer(identifier: identifier, source: source)
            layer.sourceLayerIdentifier = "landcover"
            layer.predicate = forestFilter
            layer.minimumZoomLevel = minimumZoom
            layer.maximumZoomLevel = maximumZoom
            layer.fillPattern = NSExpression(forConstantValue: forestPatternName(dark: false, dense: dense))
            layer.fillOpacity = NSExpression(forConstantValue: 0.78)
            style.insertLayer(layer, above: lastLandcoverFill)
        }
    }

    private func installWaterWavePatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let lastWaterFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "water" }) else { return }

        let waterFilter = NSPredicate(format: "class IN %@", ["ocean", "lake", "river", "pond", "dock"])
        let layers: [(String, Float, Float, Bool)] = [
            ("naviastra-water-wave-pattern", 12, 15, false),
            ("naviastra-water-wave-pattern-dense", 15, 24, true)
        ]
        for (identifier, minimumZoom, maximumZoom, dense) in layers
            where style.layer(withIdentifier: identifier) == nil {
            let layer = MLNFillStyleLayer(identifier: identifier, source: source)
            layer.sourceLayerIdentifier = "water"
            layer.predicate = waterFilter
            layer.minimumZoomLevel = minimumZoom
            layer.maximumZoomLevel = maximumZoom
            layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: false, dense: dense))
            layer.fillOpacity = NSExpression(forConstantValue: dense ? 0.2 : 0.12)
            style.insertLayer(layer, above: lastWaterFill)
        }
    }

    private func landcoverColorExpression(dark: Bool) -> NSExpression {
        let vegetation = hexColor(dark ? NaviAstraColorPalette.mapParkNight : NaviAstraColorPalette.mapParkDay)
        let forest = vegetation
        let scrub = vegetation
        let grass = vegetation
        let meadow = vegetation
        let cultivated = vegetation
        let garden = vegetation
        let wetland = vegetation
        let sand = hexColor(dark ? 0x3D3B30 : 0xEDE4C7)
        let rock = hexColor(dark ? 0x3D4142 : 0xDFDDD3)
        let ice = hexColor(dark ? 0x30434B : 0xE6F0F1)
        let byClass: [Any] = [
            "match", ["get", "class"],
            "wood", forest, "grass", grass, "farmland", cultivated,
            "wetland", wetland, "sand", sand, "rock", rock, "ice", ice, forest
        ]
        let expression: [Any] = [
            "match", ["get", "subclass"],
            ["forest", "wood"], forest,
            ["scrub", "shrubbery", "heath", "fell", "mangrove"], scrub,
            ["grass", "grassland", "golf_course", "wet_meadow"], grass,
            ["meadow"], meadow,
            ["orchard", "vineyard", "farm", "farmland", "plant_nursery"], cultivated,
            ["garden", "flowerbed", "allotments", "recreation_ground", "village_green"], garden,
            ["marsh", "reedbed", "swamp", "bog", "wetland", "saltmarsh", "tidalflat"], wetland,
            ["sand", "beach", "dune"], sand,
            ["bare_rock", "scree"], rock,
            ["glacier"], ice,
            byClass
        ]
        return NSExpression(mglJSONObject: expression)
    }

    private func waterColorExpression(dark: Bool) -> NSExpression {
        let water = hexColor(dark ? NaviAstraColorPalette.mapWaterNight : NaviAstraColorPalette.mapWaterDay)
        let expression: [Any] = [
            "match", ["get", "class"],
            "ocean", water,
            "lake", water,
            "river", water,
            "pond", water,
            "dock", water,
            "swimming_pool", water,
            water
        ]
        return NSExpression(mglJSONObject: expression)
    }

    private func forestPatternName(dark: Bool, dense: Bool) -> String {
        "naviastra-forest-\(dense ? "dense-" : "")\(dark ? "dark" : "light")"
    }

    private func waterPatternName(dark: Bool, dense: Bool) -> String {
        "naviastra-water-\(dense ? "dense-" : "")\(dark ? "dark" : "light")"
    }

    private func forestTreePattern(dark: Bool, dense: Bool) -> UIImage {
        let tileSize: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tileSize, height: tileSize), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let positions: [(CGFloat, CGFloat, CGFloat)] = dense
                ? [(7, 8, 8), (23, 6, 9), (42, 9, 8), (56, 17, 9), (13, 26, 8),
                   (34, 25, 9), (52, 36, 8), (4, 47, 8), (24, 48, 9), (43, 53, 8)]
                : [(12, 12, 10), (43, 17, 11), (28, 36, 10), (54, 48, 10), (5, 53, 9)]
            let canopy = color(dark ? 0x5C846D : 0x729A7C).withAlphaComponent(0.78).cgColor
            let highlight = color(dark ? 0x426B56 : 0x91B398).withAlphaComponent(0.74).cgColor
            let trunk = color(dark ? 0xB4A27D : 0x897653).withAlphaComponent(0.62).cgColor

            for (index, tree) in positions.enumerated() {
                let (x, y, size) = tree
                let half = size / 2
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y - half))
                path.addLine(to: CGPoint(x: x - half * 0.85, y: y + half * 0.62))
                path.addLine(to: CGPoint(x: x + half * 0.85, y: y + half * 0.62))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(index.isMultiple(of: 2) ? canopy : highlight)
                context.fillPath()

                let trunkRect = CGRect(x: x - 0.55, y: y + half * 0.48, width: 1.1, height: 1.7)
                context.setFillColor(trunk)
                context.fill(trunkRect)
            }
        }
    }

    private func waterWavePattern(dark: Bool, dense: Bool) -> UIImage {
        let tileSize: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tileSize, height: tileSize), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let rows: [CGFloat] = dense ? [8, 24, 40, 56] : [16, 48]
            context.setStrokeColor(color(dark ? 0x74AFC3 : 0x4B98B0).withAlphaComponent(0.72).cgColor)
            context.setLineWidth(dense ? 0.9 : 0.75)
            for (index, y) in rows.enumerated() {
                let offset = index.isMultiple(of: 2) ? CGFloat(0) : CGFloat(5)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -4, y: y + offset))
                path.addCurve(to: CGPoint(x: 68, y: y + offset),
                              control1: CGPoint(x: 18, y: y - 5 + offset),
                              control2: CGPoint(x: 46, y: y + 5 + offset))
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    private func hexColor(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }

    private func poiImageName(_ kind: PlacePOIMapMarkerKind, dark: Bool) -> String {
        "naviastra-poi-\(kind.rawValue)-\(dark ? "dark" : "light")"
    }

    private func poiIconExpression(dark: Bool) -> NSExpression {
        let kinds = PlacePOIMapMarkerKind.allCases.filter { $0 != .generic }
        func matchExpression(for property: String, fallback: Any) -> [Any] {
            var expression: [Any] = ["match", ["get", property]]
            for kind in kinds where !kind.tileValues.isEmpty {
                expression.append(kind.tileValues)
                expression.append(poiImageName(kind, dark: dark))
            }
            expression.append(fallback)
            return expression
        }
        let subclassMatch = matchExpression(for: "subclass", fallback: poiImageName(.generic, dark: dark))
        return NSExpression(mglJSONObject: matchExpression(for: "class", fallback: subclassMatch))
    }

    private func buildingColorExpression(neutralColor: String) -> NSExpression {
        // OpenMapTiles has an explicit `colour` tag but no building class; keep OSM color as a restrained 22% tint.
        NSExpression(mglJSONObject: [
            "interpolate", ["linear"], 0.22,
            0, neutralColor,
            1, ["to-color", ["get", "colour"], neutralColor]
        ])
    }

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
