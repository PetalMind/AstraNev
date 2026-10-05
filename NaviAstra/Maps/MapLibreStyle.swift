#if os(iOS)
import Foundation
import MapLibre
import UIKit

/// Approximate geometric solar elevation, sufficient for decorative lighting.
/// NOAA: https://gml.noaa.gov/grad/solcalc/solareqns.PDF
struct MapBuildingLighting {
    let intensity: Double
    let quiet: Bool
    var level: Int { Int((intensity * 4).rounded()) }

    static func resolve(appearance: MapAppearance, coordinate: CLLocationCoordinate2D,
                        date: Date = Date()) -> MapBuildingLighting {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let days = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        let gamma = 2 * Double.pi / days * (day - 1 + (minutes / 60 - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let solarMinutes = ((minutes + equation + 4 * coordinate.longitude).truncatingRemainder(dividingBy: 1440) + 1440)
            .truncatingRemainder(dividingBy: 1440)
        let latitude = coordinate.latitude * .pi / 180
        let hourAngle = (solarMinutes / 4 - 180) * .pi / 180
        let sineElevation = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        let elevation = asin(min(1, max(-1, sineElevation))) * 180 / .pi
        let progress = min(1, max(0, (2 - elevation) / 8))
        let intensity: Double
        switch appearance {
        case .day: intensity = 0
        case .night: intensity = 1
        case .auto: intensity = progress * progress * (3 - 2 * progress)
        }
        return MapBuildingLighting(intensity: intensity, quiet: solarMinutes < 300)
    }
}

/// NaviAstra's visual layer on top of the OpenFreeMap / OpenMapTiles schema.
/// No fabricated POI, heights, traffic, or elevation data are introduced here.
final class NaviAstraMapStyle {
    private var lastKey = ""
    private var shopLogoNames: [String: String] = [:]
    private var shopLogoImages: [String: UIImage] = [:]
    private var shopLogoDark: Bool?
    private var shopLogosEnabled = true
    private var originalPredicates: [String: NSPredicate] = [:]
    private var poiLayerIDs: [String] = []
    private var poiCategories: [MapPOICategory] = []
    private var poiDensity: Int?
    private var configured = false
    private let windowLayerID = "naviastra-building-windows"
    private let roofLayerID = "naviastra-building-window-roofs"
    private let roofDetailLayerID = "naviastra-building-roof-detail"
    private let glowLayerIDs = ["naviastra-building-light-halo", "naviastra-building-light-edge"]
    private let glowSourceID = "naviastra-building-light-segments"
    private var buildingQueryLayerID: String?

    func reset() {
        lastKey = ""
        shopLogoNames = [:]
        shopLogoImages = [:]
        shopLogoDark = nil
        originalPredicates.removeAll()
        poiLayerIDs.removeAll()
        poiCategories = []
        poiDensity = nil
        configured = false
        buildingQueryLayerID = nil
    }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool,
               activelyNavigating: Bool, zoom: Double, coordinate: CLLocationCoordinate2D) {
        if !configured {
            configure(style)
            configured = true
        }
        shopLogosEnabled = settings.shopLogosEnabled
        let density = densityLevel(for: zoom)
        let categories = settings.visiblePOICategories.sorted { $0.rawValue < $1.rawValue }
        let lighting = MapBuildingLighting.resolve(appearance: settings.appearance, coordinate: coordinate)
        let quietNight = lighting.quiet
        let brightness = (lighting.intensity * 20).rounded() / 20
        let key = "\(settings.shopLogosEnabled)-\(dark)-\(brightness)-\(quietNight)-\(activelyNavigating)-\(settings.context)-\(categories.map(\.rawValue))-\(settings.overlays.buildings3D)-\(settings.cameraMode)-\(settings.overlays.transit)"
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
            : NaviAstraColorPalette.mapMainRoadDay)
        let minorRoad = color(dark ? NaviAstraColorPalette.mapLocalRoadNight : 0xFFFFFF)
        let roadOutline = color(dark ? NaviAstraColorPalette.mapBackgroundNight
                                     : NaviAstraColorPalette.mapMainRoadOutlineDay)

        for layer in style.layers {
            if layer.identifier.hasPrefix("naviastra-weather-") { continue }
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
                    let neutralColor = hexColor(dark ? NaviAstraColorPalette.mapBuildingNight : NaviAstraColorPalette.mapBuildingDay)
                    layer.fillColor = buildingColorExpression(neutralColor: neutralColor)
                    layer.fillOpacity = NSExpression(forConstantValue: navigating ? 0.42 : 0.75)
                    layer.fillOutlineColor = NSExpression(forConstantValue: roadOutline)
                }
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer,
               layer.sourceLayerIdentifier == "building" {
                if id == windowLayerID || id == roofLayerID || id == roofDetailLayerID {
                    layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                    if id == windowLayerID {
                        layer.fillExtrusionPattern = buildingPatternExpression(dark: dark, quiet: quietNight, roof: false, level: lighting.level)
                        layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"],
                            16, 0, 17, navigating ? 0.18 : (dark ? 0.46 : 0.30),
                            18, navigating ? 0.26 : (dark ? 0.62 : 0.42)
                        ])
                    } else if id == roofDetailLayerID {
                        layer.fillExtrusionPattern = buildingPatternExpression(dark: dark, quiet: false, roof: true)
                        layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"], 16, 0,
                            17, navigating ? 0.08 : (dark ? 0.14 : 0.22),
                            19, navigating ? 0.12 : (dark ? 0.20 : 0.32)
                        ])
                    } else {
                        // Native extrusion patterns also cover roofs. An untextured,
                        // thin cap hides those marks without inventing roof geometry.
                        layer.fillExtrusionColor = buildingColorExpression(neutralColor: hexColor(dark ? NaviAstraColorPalette.mapBuildingNight : NaviAstraColorPalette.mapBuildingDay))
                        layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"], 16, 0, 17, navigating ? 0.42 : 0.85
                        ])
                    }
                    continue
                }
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = buildingColorExpression(neutralColor: hexColor(dark ? NaviAstraColorPalette.mapBuildingNight : NaviAstraColorPalette.mapBuildingDay))
                layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    14, navigating ? 0.28 : 0.48,
                    16, navigating ? 0.28 : 0.48,
                    17, navigating ? 0.42 : 0.72
                ])
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
                layer.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: 0.45)
            }
            if let layer = layer as? MLNLineStyleLayer {
                if glowLayerIDs.contains(id) {
                    layer.isVisible = lighting.intensity > 0 && settings.overlays.buildings3D && settings.cameraMode == .threeD
                    let halo = id == glowLayerIDs[0]
                    layer.lineColor = NSExpression(forConstantValue: color(0xE5BA79))
                    let strength = brightness * (quietNight ? 0.55 : 1.0) * (navigating ? 0.5 : 1.0)
                    layer.lineOpacity = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"], 16, 0,
                        17, ["*", (halo ? 0.10 : 0.14) * strength, ["get", "brightness"]],
                        19, ["*", (halo ? 0.14 : 0.18) * strength, ["get", "brightness"]]
                    ])
                    continue
                }
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
                    layer.textColor = poiColorExpression(dark: dark)
                    layer.iconScale = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"], 12, 0.64, 17, 0.82
                    ])
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
        let density = densityLevel(for: zoom)
        guard poiDensity != density else { return }
        for id in poiLayerIDs {
            guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
            layer.predicate = poiPredicate(for: id, categories: poiCategories, density: density)
        }
        poiDensity = density
    }

    private func densityLevel(for zoom: Double) -> Int {
        // Keep the current density until zoom moves clearly past the boundary.
        // This also applies when appearance or travel context changes.
        switch poiDensity {
        case 2:
            return zoom >= 16.7 ? 2 : (zoom >= 14.7 ? 1 : 0)
        case 1:
            return zoom >= 17 ? 2 : (zoom >= 14.7 ? 1 : 0)
        default:
            return zoom >= 17 ? 2 : (zoom >= 15 ? 1 : 0)
        }
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
                case "poi_r7": layer.minimumZoomLevel = 14.7
                case "poi_r20": layer.minimumZoomLevel = 16.7
                case "poi_transit": layer.minimumZoomLevel = 14
                default: break
                }
                layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
                layer.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 11, 17, 13])
                // Labels may be omitted without hiding the place's icon. Icons do not
                // compete with labels, so newly appearing text cannot displace a POI.
                layer.textAllowsOverlap = NSExpression(forConstantValue: false)
                layer.textOptional = NSExpression(forConstantValue: true)
                layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
                layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            }
            if let layer = layer as? MLNFillStyleLayer, layer.sourceLayerIdentifier == "building" {
                layer.maximumZoomLevel = 24 // Retain footprints when extrusion is disabled.
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer,
               layer.sourceLayerIdentifier == "building" {
                // OpenMapTiles omits hide_3d unless an outline must be hidden.
                // Include that missing value explicitly in the native style filter.
                layer.minimumZoomLevel = 14
                layer.predicate = NSPredicate(format: "hide_3d == nil OR hide_3d != true")
                // Keep the provider's height and base in meters at every zoom.
                // Scaling them to zero at zoom 15 made the 3D view look flat.
                layer.fillExtrusionHeight = NSExpression(mglJSONObject: [
                    "coalesce", ["get", "render_height"], 0
                ])
                layer.fillExtrusionBase = NSExpression(mglJSONObject: [
                    "coalesce", ["get", "render_min_height"], 0
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
        installBuildingWindowLayers(in: style)
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

    private func installBuildingWindowLayers(in style: MLNStyle) {
        guard style.layer(withIdentifier: windowLayerID) == nil,
              let building = style.layers.compactMap({ $0 as? MLNFillExtrusionStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "building" }),
              let sourceID = building.sourceIdentifier,
              let source = style.source(withIdentifier: sourceID) else { return }

        buildingQueryLayerID = building.identifier
        for variant in 0..<12 {
            for dark in [false, true] {
                for level in 0...4 {
                    for quiet in (level > 0 ? [false, true] : [false]) {
                        style.setImage(buildingFacadePattern(variant: variant, dark: dark, quiet: quiet, level: level),
                                       forName: buildingPatternName(variant: variant, dark: dark, quiet: quiet, roof: false, level: level))
                    }
                }
                if variant < 4 {
                    style.setImage(buildingRoofPattern(variant: variant, dark: dark),
                                   forName: buildingPatternName(variant: variant, dark: dark, quiet: false, roof: true))
                }
            }
        }
        let windows = MLNFillExtrusionStyleLayer(identifier: windowLayerID, source: source)
        windows.sourceLayerIdentifier = "building"
        windows.minimumZoomLevel = 16
        windows.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            building.predicate ?? NSPredicate(value: true),
            NSPredicate(format: "render_height >= 3")
        ])
        windows.fillExtrusionHeight = building.fillExtrusionHeight
        windows.fillExtrusionBase = building.fillExtrusionBase
        windows.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: false)
        windows.fillExtrusionRoundedCornerDistance = building.fillExtrusionRoundedCornerDistance
        windows.isVisible = false
        style.insertLayer(windows, above: building)

        let roof = MLNFillExtrusionStyleLayer(identifier: roofLayerID, source: source)
        roof.sourceLayerIdentifier = "building"
        roof.minimumZoomLevel = windows.minimumZoomLevel
        roof.predicate = windows.predicate
        let height: [Any] = ["coalesce", ["get", "render_height"], 0]
        roof.fillExtrusionBase = NSExpression(mglJSONObject: height)
        roof.fillExtrusionHeight = NSExpression(mglJSONObject: ["+", height, 0.02])
        roof.fillExtrusionRoundedCornerDistance = building.fillExtrusionRoundedCornerDistance
        roof.isVisible = false
        style.insertLayer(roof, above: windows)

        let roofDetail = MLNFillExtrusionStyleLayer(identifier: roofDetailLayerID, source: source)
        roofDetail.sourceLayerIdentifier = "building"
        roofDetail.minimumZoomLevel = windows.minimumZoomLevel
        roofDetail.predicate = windows.predicate
        roofDetail.fillExtrusionBase = roof.fillExtrusionHeight
        roofDetail.fillExtrusionHeight = NSExpression(mglJSONObject: ["+", height, 0.04])
        roofDetail.fillExtrusionRoundedCornerDistance = building.fillExtrusionRoundedCornerDistance
        roofDetail.isVisible = false
        style.insertLayer(roofDetail, above: roof)

        let glowSource = MLNShapeSource(identifier: glowSourceID, shape: nil, options: nil)
        style.addSource(glowSource)
        // Selected facade segments follow the real footprints on the ground.
        // Keep the halo below footprints, 3D geometry, route lines and labels.
        let groundAnchor = style.layers.first(where: {
            ($0 as? MLNFillStyleLayer)?.sourceLayerIdentifier == "building"
        }) ?? building
        for (index, id) in glowLayerIDs.enumerated() {
            let glow = MLNLineStyleLayer(identifier: id, source: glowSource)
            glow.minimumZoomLevel = 16
            glow.lineWidth = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"],
                16, index == 0 ? 4 : 1, 18, index == 0 ? 14 : 4, 20, index == 0 ? 22 : 6
            ])
            glow.lineBlur = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"],
                16, index == 0 ? 3 : 1, 18, index == 0 ? 10 : 3, 20, index == 0 ? 16 : 4
            ])
            glow.isVisible = false
            style.insertLayer(glow, below: groundAnchor)
        }
    }

    private func buildingPatternName(variant: Int, dark: Bool, quiet: Bool, roof: Bool, level: Int = 0) -> String {
        "naviastra-building-\(roof ? "roof" : "facade")-\(variant)-\(dark ? "dark" : "light")-\(level)-\(quiet && level > 0 ? "quiet" : "normal")"
    }

    func updateBuildingGlow(on map: MLNMapView, settings: MapSettings) {
        guard let source = map.style?.source(withIdentifier: glowSourceID) as? MLNShapeSource else { return }
        let lighting = MapBuildingLighting.resolve(appearance: settings.appearance, coordinate: map.centerCoordinate)
        guard settings.overlays.buildings3D, settings.cameraMode == .threeD,
              map.zoomLevel >= 16.5, lighting.intensity > 0,
              let buildingQueryLayerID else {
            source.shape = nil
            return
        }
        let visible = map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: Set([buildingQueryLayerID]))
        var patches: [MLNPolylineFeature] = []
        var seen = Set<String>()
        // Bound the work per settled viewport; no geometry is sampled per frame.
        for feature in visible.prefix(160) {
            let polygons: [MLNPolygon]
            if let polygon = feature as? MLNPolygon { polygons = [polygon] }
            else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
            else { continue }
            let attributes = feature.attributes
            let height = (attributes["render_height"] as? NSNumber)?.doubleValue ?? 0
            let base = (attributes["render_min_height"] as? NSNumber)?.doubleValue ?? 0
            guard height >= 3, base < 1 else { continue }
            for polygon in polygons.prefix(8) {
                guard patches.count < 480 else { break }
                let count = Int(polygon.pointCount)
                guard count >= 4, count <= 128 else { continue }
                let coordinates = polygon.coordinates
                let first = coordinates[0]
                let identity = feature.identifier.map { String(describing: $0) }
                    ?? "\(Int(first.latitude * 100_000)),\(Int(first.longitude * 100_000))"
                // Deduplicate tile fragments with the same starting geometry.
                let fragment = "\(identity):\(Int(first.latitude * 100_000)):\(Int(first.longitude * 100_000))"
                guard seen.insert(fragment).inserted else { continue }
                var seed: UInt64 = 14695981039346656037
                for byte in identity.utf8 { seed = (seed ^ UInt64(byte)) &* 1099511628211 }
                var added = 0
                for edge in 0..<(count - 1) where added < 4 && patches.count < 480 {
                    let selection = (seed &+ UInt64(edge) &* 31) % 7
                    guard selection < (lighting.quiet ? 2 : 4) else { continue }
                    let a = coordinates[edge]
                    let b = coordinates[edge + 1]
                    let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
                        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                    guard length >= 3, length < 500 else { continue }
                    let half = min(0.22, 7 / length)
                    let middle = 0.35 + Double((seed &+ UInt64(edge)) % 4) * 0.1
                    var segment = [middle - half, middle + half].map { fraction in
                        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                               longitude: a.longitude + (b.longitude - a.longitude) * fraction)
                    }
                    let patch = MLNPolylineFeature(coordinates: &segment, count: 2)
                    patch.attributes = ["brightness": 0.45 + Double((seed &+ UInt64(edge)) % 6) * 0.1]
                    patches.append(patch)
                    added += 1
                }
            }
        }
        source.shape = patches.isEmpty ? nil : MLNShapeCollectionFeature(shapes: patches)
    }

    private func buildingPatternExpression(dark: Bool, quiet: Bool, roof: Bool, level: Int = 0) -> NSExpression {
        // Prefer a stable tile feature ID, with provider height as a fallback.
        // Never infer surveyed materials or occupancy from these variants.
        let heightSeed: [Any] = ["*", ["coalesce", ["get", "render_height"], 0], 13]
        let seed: [Any] = ["to-number", ["coalesce", ["id"], heightSeed], heightSeed]
        let count = roof ? 4 : 12
        let variant: [Any] = ["%", ["abs", ["floor", seed]], count]
        var expression: [Any] = ["match", variant]
        for index in 0..<(count - 1) {
            expression.append(index)
            expression.append(buildingPatternName(variant: index, dark: dark, quiet: quiet, roof: roof, level: level))
        }
        expression.append(buildingPatternName(variant: count - 1, dark: dark, quiet: quiet, roof: roof, level: level))
        return NSExpression(mglJSONObject: expression)
    }

    private func buildingFacadePattern(variant: Int, dark: Bool, quiet: Bool, level: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            let context = renderer.cgContext
            let dayMaterials: [UInt32] = [0xB8A99A, 0xD7D3C9, 0xBDC4C6, 0xA4BAC4]
            let nightMaterials: [UInt32] = [0x302D30, 0x2C3036, 0x293139, 0x24323E]
            let material = variant % 4
            let layout = variant / 4
            let base = color((dark ? nightMaterials : dayMaterials)[material])
            context.setFillColor(base.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setStrokeColor(UIColor(white: dark ? 0.65 : 0.25, alpha: dark ? 0.06 : 0.10).cgColor)
            context.setLineWidth(0.6)
            if material == 0 {
                // Staggered brick joints, kept much weaker than the windows.
                for row in 0..<16 {
                    let y = CGFloat(row * 4)
                    context.move(to: CGPoint(x: 0, y: y))
                    context.addLine(to: CGPoint(x: 64, y: y))
                    for column in 0..<8 {
                        let x = CGFloat(column * 8 + (row.isMultiple(of: 2) ? 0 : 4))
                        context.move(to: CGPoint(x: x, y: y))
                        context.addLine(to: CGPoint(x: x, y: y + 4))
                    }
                }
                context.strokePath()
            } else if material == 2 || material == 3 {
                let spacing = material == 3 ? 8 : 32
                for offset in stride(from: 0, to: 64, by: spacing) {
                    context.move(to: CGPoint(x: CGFloat(offset), y: 0))
                    context.addLine(to: CGPoint(x: CGFloat(offset), y: 64))
                    context.move(to: CGPoint(x: 0, y: CGFloat(offset)))
                    context.addLine(to: CGPoint(x: 64, y: CGFloat(offset)))
                }
                context.strokePath()
            } else {
                // Deterministic plaster grain; no frame-to-frame randomness.
                context.setFillColor(UIColor(white: dark ? 0.8 : 0.2, alpha: 0.035).cgColor)
                for index in 0..<96 {
                    context.fill(CGRect(x: CGFloat((index * 17) % 64), y: CGFloat((index * 29) % 64), width: 1, height: 1))
                }
            }
            let eveningWindows: [Set<Int>] = [[1, 3, 4, 7, 10, 12], [0, 5, 6, 9, 14],
                                              [2, 3, 7, 8, 12, 15], [0, 1, 5, 7, 10, 11, 14]]
            let quietWindows: [Set<Int>] = [[3, 10], [5], [7, 12], [1, 11]]
            let illuminated = (quiet ? quietWindows : eveningWindows)[material]
            for row in 0..<4 {
                for column in 0..<4 {
                    let index = row * 4 + column
                    let width: CGFloat = material == 3 ? 9 : (material == 1 ? 5 : 4)
                    let rect = CGRect(x: CGFloat(column * 16) + (16 - width) / 2,
                                      y: CGFloat(row * 16 + 5), width: width, height: material == 2 ? 5 : 6)
                    let lit = illuminated.contains((index + layout * 5) % 16) && level > 0
                    if lit {
                        let strength = CGFloat(level) / 4
                        context.setFillColor(color(0xD6B782).withAlphaComponent(0.10 * strength).cgColor)
                        context.fill(rect.insetBy(dx: -1.5, dy: -1.5))
                        context.setFillColor(color((index + layout).isMultiple(of: 3) ? 0xD8D1B2 : 0xE2BD82)
                            .withAlphaComponent(0.35 + 0.65 * strength).cgColor)
                    } else {
                        context.setFillColor(color(dark ? 0x202833 : (material == 3 ? 0x7899A9 : 0x8C9FA9)).cgColor)
                    }
                    context.fill(rect)
                    if lit {
                        // Bright center and a softer border suggest an illuminated
                        // interior while remaining within the native texture shader.
                        context.setFillColor(color(0xF5DFB5).withAlphaComponent(CGFloat(level) / 4 * 0.28).cgColor)
                        context.fill(rect.insetBy(dx: 0.8, dy: 0.8))
                    }
                    context.setFillColor(base.withAlphaComponent(0.65).cgColor)
                    context.fill(CGRect(x: rect.midX - 0.25, y: rect.minY, width: 0.5, height: rect.height))
                }
            }
        }
    }

    private func buildingRoofPattern(variant: Int, dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            let context = renderer.cgContext
            let dayRoofs: [UInt32] = [0xA7998A, 0xC4C1B7, 0xADB5B8, 0xA1AFB4]
            let nightRoofs: [UInt32] = [0x302D30, 0x2B3035, 0x293138, 0x26323B]
            context.setFillColor(color((dark ? nightRoofs : dayRoofs)[variant]).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setStrokeColor(UIColor(white: dark ? 0.65 : 0.25, alpha: dark ? 0.10 : 0.16).cgColor)
            context.setLineWidth(0.7)
            let spacing = variant == 0 ? 8 : (variant == 1 ? 16 : 32)
            for offset in stride(from: 0, to: 64, by: spacing) {
                let position = CGFloat(offset)
                context.move(to: CGPoint(x: 0, y: position))
                context.addLine(to: CGPoint(x: 64, y: position))
                context.move(to: CGPoint(x: position, y: 0))
                context.addLine(to: CGPoint(x: position, y: 64))
            }
            context.strokePath()
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
            layer.fillOpacity = NSExpression(forConstantValue: 0.18)
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
            layer.fillOpacity = NSExpression(forConstantValue: dense ? 0.08 : 0.05)
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

    /// Match the exact tile object, preserving the tile's position, label and tap behavior.
    static var shopLogoKeyExpression: [Any] {
        ["concat", ["to-string", ["coalesce", ["get", "osm_id"], ["id"], ""]], "|",
         ["coalesce", ["get", "name"], ""], "|", ["coalesce", ["get", "class"], ""], "|",
         ["coalesce", ["get", "subclass"], ""]]
    }

    func setShopLogos(_ images: [String: UIImage], on style: MLNStyle, dark: Bool) {
        guard shopLogoDark != dark || images.count != shopLogoImages.count
                || images.contains(where: { shopLogoImages[$0.key] !== $0.value }) else { return }
        shopLogoImages = images
        shopLogoDark = dark
        // Reuse a bounded pool of sprite names while the viewport changes.
        let oldNames = Set(shopLogoNames.values)
        shopLogoNames = [:]
        for (index, key) in images.keys.sorted().enumerated() {
            let name = "naviastra-shop-logo-\(index)"
            shopLogoNames[key] = name
            style.setImage(images[key]!.shopPOIMarkerImage(), forName: name)
        }
        for id in poiLayerIDs {
            (style.layer(withIdentifier: id) as? MLNSymbolStyleLayer)?.iconImageName = poiIconExpression(dark: dark)
        }
        for name in oldNames.subtracting(shopLogoNames.values) { style.removeImage(forName: name) }
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
        let classMatch = matchExpression(for: "class", fallback: poiImageName(.generic, dark: dark))
        let fallback = matchExpression(for: "subclass", fallback: classMatch)
        guard shopLogosEnabled, !shopLogoNames.isEmpty else { return NSExpression(mglJSONObject: fallback) }
        var logos: [Any] = ["match", Self.shopLogoKeyExpression]
        for key in shopLogoNames.keys.sorted() { logos += [key, shopLogoNames[key]!] }
        logos.append(fallback)
        return NSExpression(mglJSONObject: logos)
    }

    private func poiColorExpression(dark: Bool) -> NSExpression {
        func matchExpression(for property: String, fallback: Any) -> [Any] {
            var expression: [Any] = ["match", ["get", property]]
            for kind in PlacePOIMapMarkerKind.allCases where !kind.tileValues.isEmpty {
                expression.append(kind.tileValues)
                expression.append(hexColor(kind.colorHex(dark: dark)))
            }
            expression.append(fallback)
            return expression
        }
        let classMatch = matchExpression(for: "class", fallback: hexColor(PlacePOIMapMarkerKind.generic.colorHex(dark: dark)))
        let fallback = matchExpression(for: "subclass", fallback: classMatch)
        guard shopLogosEnabled, !shopLogoNames.isEmpty else { return NSExpression(mglJSONObject: fallback) }
        var logos: [Any] = ["match", Self.shopLogoKeyExpression]
        for key in shopLogoNames.keys.sorted() { logos += [key, shopLogoNames[key]!] }
        logos.append(fallback)
        return NSExpression(mglJSONObject: logos)
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
