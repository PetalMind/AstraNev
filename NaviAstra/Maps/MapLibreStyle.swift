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
    private var satelliteStyle = SatelliteMapStyle()
    private var shopLogoNames: [String: String] = [:]
    private var shopLogoImages: [String: UIImage] = [:]
    private var shopLogoDark: Bool?
    private var shopLogosEnabled = true
    private var originalPredicates: [String: NSPredicate] = [:]
    private var poiLayerIDs: [String] = []
    private var poiCategories: [MapPOICategory] = []
    private var poiDensity: Int?
    private var poiRouteFilterKey = ""
    private var poiRoutePredicate = NSPredicate(value: true)
    private var configured = false
    private let windowLayerID = "naviastra-building-windows"
    private let roofLayerID = "naviastra-building-window-roofs"
    private let roofDetailLayerID = "naviastra-building-roof-detail"
    private let glowLayerIDs = ["naviastra-building-light-halo", "naviastra-building-light-edge"]
    private let glowSourceID = "naviastra-building-light-segments"
    private var buildingQueryLayerID: String?
    private var buildingHeightKey = "render_height"
    private var buildingBaseKey = "render_min_height"

    func reset() {
        lastKey = ""
        satelliteStyle = SatelliteMapStyle()
        shopLogoNames = [:]
        shopLogoImages = [:]
        shopLogoDark = nil
        originalPredicates.removeAll()
        poiLayerIDs.removeAll()
        poiCategories = []
        poiDensity = nil
        poiRouteFilterKey = ""
        poiRoutePredicate = NSPredicate(value: true)
        configured = false
        buildingQueryLayerID = nil
        buildingHeightKey = "render_height"
        buildingBaseKey = "render_min_height"
    }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool,
               activelyNavigating: Bool, zoom: Double, coordinate: CLLocationCoordinate2D) {
        if !configured {
            configure(style)
            configured = true
        }
        shopLogosEnabled = settings.shopLogosEnabled && zoom >= 17
        let density = densityLevel(for: zoom)
        let categories = settings.visiblePOICategories.sorted { $0.rawValue < $1.rawValue }
        let lighting = MapBuildingLighting.resolve(appearance: settings.appearance, coordinate: coordinate)
        let quietNight = lighting.quiet
        let brightness = (lighting.intensity * 20).rounded() / 20
        let key = "\(settings.baseMap)-\(shopLogosEnabled)-\(dark)-\(brightness)-\(quietNight)-\(activelyNavigating)-\(settings.context)-\(categories.map(\.rawValue))-\(settings.overlays.buildings3D)-\(settings.cameraMode)-\(settings.overlays.transit)-\(settings.overlays.poi)"
        guard key != lastKey else {
            updatePOIDensity(to: style, zoom: zoom)
            satelliteStyle.apply(to: style, enabled: settings.baseMap == .satellite)
            return
        }
        satelliteStyle.restoreStandard(in: style)
        lastKey = key
        poiCategories = categories
        let navigating = settings.context.isNavigating
        let transitionDuration = navigating ? 0.16 : 0.4
        style.transition = MLNTransition(duration: transitionDuration, delay: 0)
        let light = style.light
        let lightPosition = MLNSphericalPositionMake(1.15, dark ? 220 : 225, dark ? 55 : 50)
        light.anchor = NSExpression(forConstantValue: "map")
        light.position = NSExpression(forConstantValue: NSValue(mlnSphericalPosition: lightPosition))
        light.intensity = NSExpression(forConstantValue: dark ? 0.30 : 0.52)
        light.color = NSExpression(forConstantValue: color(dark ? 0xC3D2E2 : 0xFFF3E4))
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
        let minorRoad = color(dark ? 0x26282D : 0xE8E9EC)
        let roadOutline = color(dark ? NaviAstraColorPalette.mapBackgroundNight
                                     : NaviAstraColorPalette.mapMainRoadOutlineDay)

        for layer in style.layers {
            if layer.identifier.hasPrefix("naviastra-weather-") { continue }
            if layer.identifier.hasPrefix(MapEnvironmentStyle.prefix) { continue }
            let id = layer.identifier
            if let layer = layer as? MLNBackgroundStyleLayer {
                layer.backgroundColor = NSExpression(forConstantValue: background)
            }
            // The low-zoom raster would otherwise retain its daytime colors at night.
            if id == "natural_earth" { layer.isVisible = !dark }
            if let layer = layer as? MLNFillStyleLayer {
                if id == "naviastra-forest-tree-pattern" {
                    layer.fillPattern = forestPatternExpression(dark: dark, dense: false)
                    continue
                }
                if id == "naviastra-forest-tree-pattern-dense" {
                    layer.fillPattern = forestPatternExpression(dark: dark, dense: true)
                    continue
                }
                if id == "naviastra-water-wave-pattern" {
                    layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: dark))
                    let strength = navigating ? 0.55 : 1.0
                    layer.fillOpacity = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"],
                        12, 0, 14, 0.10 * strength, 17, 0.16 * strength
                    ])
                    continue
                }
                let source = layer.sourceLayerIdentifier ?? ""
                let fill: UIColor
                switch source {
                case "water":
                    layer.fillColor = waterColorExpression(dark: dark)
                    // Use the native antialiased edge in the fill color,
                    // wit  hout a contrasting outline.
                    layer.fillAntialiased = NSExpression(forConstantValue: true)
                    layer.fillOutlineColor = nil
                    layer.fillOpacity = NSExpression(mglJSONObject: [
                        "case", ["==", ["get", "intermittent"], 1], 0.82, 1
                    ])
                    continue
                case "waterway": fill = water
                case "park": fill = color(dark ? NaviAstraColorPalette.mapParkNight : NaviAstraColorPalette.mapParkDay)
                case "landcover":
                    layer.fillColor = landcoverColorExpression(dark: dark)
                    if id == "landcover_grass" {
                        layer.fillOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"],
                            13, ["match", ["get", "subclass"], "park", 1, 0], 15, 1
                        ])
                    }
                    continue
                case "landuse":
                    layer.fillColor = MapEnvironmentStyle.landuseColor(dark: dark)
                    continue
                case "building": fill = color(dark ? NaviAstraColorPalette.mapBuildingNight
                                                   : NaviAstraColorPalette.mapBuildingDay)
                case "aeroway": fill = color(dark ? 0x2B3C48 : 0xDCE4E8)
                default: continue
                }
                layer.fillColor = NSExpression(forConstantValue: fill)
                if source == "building" {
                    layer.fillColor = MapBuildingAppearance.color(dark: dark, heightKey: "render_height")
                    layer.fillOpacity = NSExpression(forConstantValue: navigating ? 0.50 : 0.88)
                    layer.fillOutlineColor = NSExpression(forConstantValue: color(dark ? 0x48515B : 0xBAB8B2))
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
                            16, 0, 17, navigating ? 0.22 : (dark ? 0.58 : 0.40),
                            18, navigating ? 0.32 : (dark ? 0.70 : 0.56)
                        ])
                    } else if id == roofDetailLayerID {
                        layer.fillExtrusionPattern = buildingPatternExpression(dark: dark, quiet: false, roof: true)
                        layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"], 16, 0,
                            17, navigating ? 0.10 : (dark ? 0.16 : 0.24),
                            19, navigating ? 0.16 : (dark ? 0.24 : 0.34)
                        ])
                    } else {
                        // Native extrusion patterns also cover roofs. An untextured,
                        // thin cap hides those marks without inventing roof geometry.
                        layer.fillExtrusionColor = MapBuildingAppearance.color(dark: dark, roof: true, heightKey: buildingHeightKey)
                        layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                            "interpolate", ["linear"], ["zoom"], 16, 0, 17, navigating ? 0.68 : 0.98
                        ])
                    }
                    continue
                }
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = MapBuildingAppearance.color(dark: dark, heightKey: "render_height")
                layer.fillExtrusionOpacity = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    16, navigating ? 0.42 : (dark ? 0.60 : 0.68),
                    17, navigating ? 0.58 : (dark ? 0.90 : 0.94)
                ])
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
                layer.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: MapBuildingAppearance.cornerDistance)
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
                if id == "naviastra-water-soft-shore" {
                    layer.lineColor = NSExpression(forConstantValue: water)
                    continue
                }
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
                    layer.lineJoin = NSExpression(forConstantValue: "round")
                    layer.lineCap = NSExpression(forConstantValue: "round")
                    layer.lineBlur = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"], 9, 0.2, 16, 0.65
                    ])
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
                } else if source == "water_name" || source == "waterway" {
                    layer.text = NSExpression(mglJSONObject: [
                        "coalesce", ["get", "name:pl"], ["get", "name"], ["get", "name:latin"], ""
                    ])
                    layer.textColor = NSExpression(forConstantValue: color(dark ? 0x8AA9B5 : 0x567B86))
                    layer.textHaloColor = NSExpression(forConstantValue: water.withAlphaComponent(0.65))
                    layer.textHaloWidth = NSExpression(forConstantValue: 0.6)
                } else if id.contains("highway-name-minor") || id.contains("highway-name-path") {
                    layer.textOpacity = NSExpression(forConstantValue: navigating && settings.context == .driving ? 0.4 : 1.0)
                } else if source == "place" {
                    layer.textOpacity = NSExpression(forConstantValue: navigating ? 0.6 : 1.0)
                }
            }
        }
        MapEnvironmentStyle.apply(to: style, settings: settings, dark: dark)
        satelliteStyle.apply(to: style, enabled: settings.baseMap == .satellite)
        poiDensity = density
    }

    func updatePOIDensity(to style: MLNStyle, zoom: Double) {
        guard configured else { return }
        let density = densityLevel(for: zoom)
        guard poiDensity != density else { return }
        for id in poiLayerIDs {
            guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
            layer.predicate = poiPredicate(for: id, categories: poiCategories, density: density)
            layer.isVisible = !poiCategories.isEmpty
        }
        poiDensity = density
    }

    func updatePOIRouteContext(_ state: NavigationState, context: MapDisplayContext) {
        let filtered = context == .driving || context == .routePreview || context == .approachingDestination
        let traveling = state.status == .navigating || state.status == .rerouting
        let confirmed = !traveling || MapDisplayPriorityEngine.canPresentRouteAlerts(state)
        let bucket = Int(state.roadAlertRouteDistance / 100)
        let key = "\(filtered)-\(confirmed)-\(state.route?.id.uuidString ?? "none")-\(traveling ? bucket : 0)"
        guard key != poiRouteFilterKey else { return }
        poiRouteFilterKey = key
        poiDensity = nil
        guard filtered else { poiRoutePredicate = NSPredicate(value: true); return }
        guard confirmed, let route = state.route else { poiRoutePredicate = NSPredicate(value: false); return }
        let geometry = RouteProgressGeometry(route)
        let start = traveling ? max(0, Double(bucket) * 100) : 0
        let end = min(geometry.length, start + (traveling ? 5_000 : 20_000))
        var polygons: [[[[Double]]]] = []
        for distance in stride(from: start, through: end, by: 100.0) {
            guard let center = geometry.coordinate(at: distance) else { continue }
            let dy = 125.0 / 111_320
            let dx = dy / max(0.1, cos(center.latitude * .pi / 180))
            let x = center.longitude, y = center.latitude
            polygons.append([[[x - dx, y - dy], [x + dx, y - dy], [x + dx, y + dy],
                              [x - dx, y + dy], [x - dx, y - dy]]])
        }
        poiRoutePredicate = polygons.isEmpty ? NSPredicate(value: false) : NSPredicate(mglJSONObject: [
            "within", ["type": "MultiPolygon", "coordinates": polygons]
        ])
    }

    private func densityLevel(for zoom: Double) -> Int {
        Int(max(0, min(24, zoom)).rounded(.down))
    }

    private func poiPredicate(for layerID: String, categories: [MapPOICategory], density: Int) -> NSPredicate {
        let eligible = categories.filter { density >= MapDisplayPriorityEngine.minimumZoom(for: $0) }
        let categoryPredicates = eligible.map { category -> NSPredicate in
            // At overview zoom only the provider's most prominent attractions and airports remain.
            let values = density < 12 && category == .transit ? ["airport"] : category.tileValues
            let rank = density < 12 ? 1 : (density < 13 ? 3 : (density < 15 ? 19 : 1_000))
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "class IN %@ OR subclass IN %@", values, values),
                NSPredicate(format: "rank <= %d", rank)
            ])
        }
        let categoryPredicate = categoryPredicates.isEmpty ? NSPredicate(value: false)
            : NSCompoundPredicate(orPredicateWithSubpredicates: categoryPredicates)
        let providerTransitValues = MapPOICategory.transit.tileValues.filter { $0 != "airport" }
        let hideProviderTransitPredicate = NSPredicate(
            format: "NOT (class IN %@ OR subclass IN %@)", providerTransitValues, providerTransitValues)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            originalPredicates[layerID] ?? NSPredicate(value: true),
            categoryPredicate,
            hideProviderTransitPredicate,
            poiRoutePredicate
        ])
    }

    private func configure(_ style: MLNStyle) {
        for kind in PlacePOIMapMarkerKind.allCases {
            style.setImage(kind.makeMapStyleImage(dark: false), forName: poiImageName(kind, dark: false))
            style.setImage(kind.makeMapStyleImage(dark: true), forName: poiImageName(kind, dark: true))
        }
        for dark in [false, true] {
            for leaf in ["unknown", "broadleaved", "needleleaved", "mixed"] {
                for dense in [false, true] {
                    style.setImage(forestTreePattern(dark: dark, dense: dense, leaf: leaf),
                                   forName: forestPatternName(dark: dark, dense: dense, leaf: leaf))
                }
            }
            style.setImage(waterWavePattern(dark: dark), forName: waterPatternName(dark: dark))
        }
        for layer in style.layers {
            if let layer = layer as? MLNSymbolStyleLayer, layer.sourceLayerIdentifier == "poi" {
                poiLayerIDs.append(layer.identifier)
                if let predicate = layer.predicate { originalPredicates[layer.identifier] = predicate }
                switch layer.identifier {
                case "poi_r1": layer.minimumZoomLevel = 10
                case "poi_r7": layer.minimumZoomLevel = 13
                case "poi_r20": layer.minimumZoomLevel = 15
                case "poi_transit": layer.minimumZoomLevel = 14
                default: break
                }
                layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
                layer.textFontSize = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 11, 17, 13])
                // Labels may be omitted without hiding the place's icon. Icons do not
                // compete with labels, so newly appearing text cannot displace a POI.
                layer.textAllowsOverlap = NSExpression(forConstantValue: false)
                layer.textOptional = NSExpression(forConstantValue: true)
                layer.iconAllowsOverlap = NSExpression(forConstantValue: false)
                layer.iconIgnoresPlacement = NSExpression(forConstantValue: false)
                let priorities: [Any] = MapPOICategory.allCases.flatMap { category -> [Any] in
                    [category.tileValues, -MapDisplayPriorityEngine.priority(for: category)]
                }
                layer.symbolSortKey = NSExpression(mglJSONObject:
                    ["match", ["coalesce", ["get", "subclass"], ["get", "class"]]] + priorities + [0])
            }
            if let layer = layer as? MLNFillStyleLayer, layer.sourceLayerIdentifier == "building" {
                layer.minimumZoomLevel = 15
                layer.maximumZoomLevel = 24 // Retain footprints when extrusion is disabled.
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer,
               layer.sourceLayerIdentifier == "building" {
                // OpenMapTiles omits hide_3d unless an outline must be hidden.
                // Include that missing value explicitly in the native style filter.
                layer.minimumZoomLevel = 16
                layer.predicate = NSPredicate(format: "(hide_3d == nil OR hide_3d != true) AND render_height > 0")
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
        installWaterShorelineLayer(in: style)
        installWaterWavePatternLayers(in: style)
        MapEnvironmentStyle.configure(in: style)
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
              let building = (style.layer(withIdentifier: MapTilerEnvironmentStyle.buildingLayerID) as? MLNFillExtrusionStyleLayer)
                ?? style.layers.compactMap({ $0 as? MLNFillExtrusionStyleLayer })
                    .last(where: { $0.sourceLayerIdentifier == "building" }),
              let sourceID = building.sourceIdentifier,
              let source = style.source(withIdentifier: sourceID) else { return }

        buildingQueryLayerID = building.identifier
        let planet = building.identifier == MapTilerEnvironmentStyle.buildingLayerID
        buildingHeightKey = planet ? "height" : "render_height"
        buildingBaseKey = planet ? "height_min" : "render_min_height"
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
            NSPredicate(format: "%K >= 3", buildingHeightKey)
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
        let height: [Any] = ["coalesce", ["get", buildingHeightKey], 0]
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
            let height = (attributes[buildingHeightKey] as? NSNumber)?.doubleValue ?? 0
            let base = (attributes[buildingBaseKey] as? NSNumber)?.doubleValue ?? 0
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
        let count = roof ? 4 : 12
        let variant = MapBuildingAppearance.variant(heightKey: buildingHeightKey, count: count)
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
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            let context = renderer.cgContext
            let material = variant % 4
            let layout = variant / 4
            let base = color((dark ? MapBuildingAppearance.nightFacades : MapBuildingAppearance.dayFacades)[material])
            context.setFillColor(base.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setStrokeColor(UIColor(white: dark ? 0.65 : 0.25, alpha: dark ? 0.045 : 0.065).cgColor)
            context.setLineWidth(0.5)
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
                // Fine floor seams give the facade depth without strong striping.
                let floorY = CGFloat(row * 16)
                context.setFillColor(UIColor(white: 1, alpha: dark ? 0.025 : 0.16).cgColor)
                context.fill(CGRect(x: 0, y: floorY, width: 64, height: 0.5))
                context.setFillColor(UIColor(white: 0, alpha: dark ? 0.04 : 0.055).cgColor)
                context.fill(CGRect(x: 0, y: floorY + 15.5, width: 64, height: 0.5))
                for column in 0..<4 {
                    let index = row * 4 + column
                    let width: CGFloat = material == 3 ? 9 : (material == 1 ? 5 : 4)
                    let rect = CGRect(x: CGFloat(column * 16) + (16 - width) / 2,
                                      y: CGFloat(row * 16 + 5), width: width, height: material == 2 ? 5 : 6)
                    let lit = illuminated.contains((index + layout * 5) % 16) && level > 0
                    // Recessed opening, slim frame and sill remain legible at close zoom.
                    context.setFillColor(UIColor(white: 0, alpha: dark ? 0.18 : 0.12).cgColor)
                    context.fill(rect.insetBy(dx: -0.75, dy: -0.75).offsetBy(dx: 0.4, dy: 0.6))
                    context.setFillColor(color(dark ? 0x617080 : 0xF1EEE7).withAlphaComponent(dark ? 0.42 : 0.75).cgColor)
                    context.fill(rect.insetBy(dx: -0.4, dy: -0.4))
                    if lit {
                        let strength = CGFloat(level) / 4
                        context.setFillColor(color(0xD6B782).withAlphaComponent(0.10 * strength).cgColor)
                        context.fill(rect.insetBy(dx: -1.25, dy: -1.25))
                        context.setFillColor(color((index + layout).isMultiple(of: 3) ? 0xDCD6BC : 0xE8C797)
                            .withAlphaComponent(0.35 + 0.65 * strength).cgColor)
                    } else {
                        context.setFillColor(color(dark ? 0x202C38 : (material == 3 ? 0x728F9E : 0x859AA5)).cgColor)
                    }
                    context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 0.5).cgPath)
                    context.fillPath()
                    if lit {
                        // Bright center and a softer border suggest an illuminated
                        // interior while remaining within the native texture shader.
                        context.setFillColor(color(0xF5DFB5).withAlphaComponent(CGFloat(level) / 4 * 0.28).cgColor)
                        context.fill(rect.insetBy(dx: 0.8, dy: 0.8))
                    } else {
                        // A restrained glass reflection, strongest along the upper edge.
                        context.setFillColor(UIColor(white: 1, alpha: dark ? 0.045 : 0.24).cgColor)
                        context.fill(CGRect(x: rect.minX + 0.5, y: rect.minY + 0.5, width: rect.width - 1, height: 0.7))
                        context.setFillColor(UIColor(white: 1, alpha: dark ? 0.025 : 0.10).cgColor)
                        context.fill(CGRect(x: rect.minX + 0.5, y: rect.minY + 1.2, width: rect.width * 0.35, height: rect.height - 1.7))
                    }
                    context.setFillColor(base.withAlphaComponent(0.65).cgColor)
                    context.fill(CGRect(x: rect.midX - 0.25, y: rect.minY, width: 0.5, height: rect.height))
                    if material != 3 {
                        context.fill(CGRect(x: rect.minX, y: rect.midY - 0.2, width: rect.width, height: 0.4))
                    }
                    context.setFillColor(UIColor(white: dark ? 0.6 : 1, alpha: dark ? 0.12 : 0.42).cgColor)
                    context.fill(CGRect(x: rect.minX - 0.75, y: rect.maxY + 0.5, width: rect.width + 1.5, height: 0.6))
                }
            }
        }
    }

    private func buildingRoofPattern(variant: Int, dark: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(color((dark ? MapBuildingAppearance.nightRoofs : MapBuildingAppearance.dayRoofs)[variant]).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setStrokeColor(UIColor(white: dark ? 0.7 : 0.2, alpha: dark ? 0.07 : 0.10).cgColor)
            context.setLineWidth(0.5)
            // Quiet seams replace the prominent checkerboard; no invented roof objects.
            let spacing = variant == 0 ? 8 : (variant == 1 ? 32 : 16)
            for row in 0..<(64 / spacing) {
                let position = CGFloat(row * spacing) + 0.25
                if variant == 2 {
                    context.move(to: CGPoint(x: position, y: 0))
                    context.addLine(to: CGPoint(x: position, y: 64))
                } else {
                    context.move(to: CGPoint(x: 0, y: position))
                    context.addLine(to: CGPoint(x: 64, y: position))
                    if variant == 0 || variant == 3 {
                        for column in 0..<4 {
                            let x = CGFloat(column * 16 + (row.isMultiple(of: 2) ? 0 : 8)) + 0.25
                            context.move(to: CGPoint(x: x, y: position))
                            context.addLine(to: CGPoint(x: x, y: position + CGFloat(spacing)))
                        }
                    }
                }
            }
            context.strokePath()
            context.setFillColor(UIColor(white: dark ? 0.8 : 0.2, alpha: 0.025).cgColor)
            for index in 0..<64 {
                context.fill(CGRect(x: CGFloat((index * 19) % 64), y: CGFloat((index * 37) % 64), width: 0.5, height: 0.5))
            }
        }
    }

    private func installForestTreePatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let lastLandcoverFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "landcover" }) else { return }

        let forestFilter = NSPredicate(format: "class == %@ OR subclass IN %@", "wood", ["forest", "wood"])
        let waterAnchor = style.layers.first {
            guard $0 is MLNFillStyleLayer || $0 is MLNLineStyleLayer,
                  let layer = $0 as? MLNVectorStyleLayer else { return false }
            return layer.sourceLayerIdentifier == "water" || layer.sourceLayerIdentifier == "waterway"
        }
        let layers: [(String, Float, Float, Bool)] = [
            ("naviastra-forest-tree-pattern", 16, 18, false),
            ("naviastra-forest-tree-pattern-dense", 18, 24, true)
        ]
        for (identifier, minimumZoom, maximumZoom, dense) in layers
            where style.layer(withIdentifier: identifier) == nil {
            let layer = MLNFillStyleLayer(identifier: identifier, source: source)
            layer.sourceLayerIdentifier = "landcover"
            layer.predicate = forestFilter
            layer.minimumZoomLevel = minimumZoom
            layer.maximumZoomLevel = maximumZoom
            layer.fillPattern = forestPatternExpression(dark: false, dense: dense)
            layer.fillOpacity = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"], 16, 0, 17, 0.10, 18, 0.12
            ])
            if let waterAnchor { style.insertLayer(layer, below: waterAnchor) }
            else { style.insertLayer(layer, above: lastLandcoverFill) }
        }
    }

    private func installWaterShorelineLayer(in style: MLNStyle) {
        let identifier = "naviastra-water-soft-shore"
        guard style.layer(withIdentifier: identifier) == nil,
              let waterFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .first(where: { $0.sourceLayerIdentifier == "water" }),
              let sourceID = waterFill.sourceIdentifier,
              let source = style.source(withIdentifier: sourceID) else { return }

        let shore = MLNLineStyleLayer(identifier: identifier, source: source)
        shore.sourceLayerIdentifier = "water"
        shore.predicate = waterFill.predicate
        shore.minimumZoomLevel = waterFill.minimumZoomLevel
        shore.maximumZoomLevel = waterFill.maximumZoomLevel
        shore.lineJoin = NSExpression(forConstantValue: "round")
        shore.lineCap = NSExpression(forConstantValue: "round")
        shore.lineWidth = NSExpression(mglJSONObject: [
            "interpolate", ["linear"], ["zoom"], 8, 0.6, 12, 2.0, 16, 3.5
        ])
        shore.lineBlur = NSExpression(mglJSONObject: [
            "interpolate", ["linear"], ["zoom"], 8, 0.5, 12, 1.2, 16, 2.0
        ])
        shore.lineOpacity = NSExpression(mglJSONObject: [
            "case", ["==", ["get", "intermittent"], 1], 0.12, 0.24
        ])
        // The opaque water fill masks the inner half and clipped tile edges.
        // Only a faint feather remains on land along the real shoreline.
        style.insertLayer(shore, below: waterFill)
    }

    private func installWaterWavePatternLayers(in style: MLNStyle) {
        let identifier = "naviastra-water-wave-pattern"
        guard style.layer(withIdentifier: identifier) == nil,
              let lastWaterFill = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "water" }),
              let sourceID = lastWaterFill.sourceIdentifier,
              let source = style.source(withIdentifier: sourceID) else { return }

        let layer = MLNFillStyleLayer(identifier: identifier, source: source)
        layer.sourceLayerIdentifier = "water"
        layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            lastWaterFill.predicate ?? NSPredicate(value: true),
            NSPredicate(format: "class IN %@", ["ocean", "lake", "river", "pond", "dock"]),
            NSPredicate(format: "intermittent == nil OR intermittent != 1")
        ])
        layer.minimumZoomLevel = 12
        layer.maximumZoomLevel = 24
        layer.fillPattern = NSExpression(forConstantValue: waterPatternName(dark: false))
        layer.fillOpacity = NSExpression(forConstantValue: 0)
        // One texture fades in continuously instead of switching at zoom 15.
        style.insertLayer(layer, above: lastWaterFill)
    }

    private func landcoverColorExpression(dark: Bool) -> NSExpression {
        let park = hexColor(dark ? 0x293E32 : 0xD3E3C6)
        let forest = hexColor(dark ? 0x21362B : 0xB9D3B2)
        let scrub = hexColor(dark ? 0x2D4032 : 0xC5D8B9)
        let grass = hexColor(dark ? 0x324437 : 0xDCE8CF)
        let meadow = hexColor(dark ? 0x344638 : 0xE0E9D2)
        let cultivated = hexColor(dark ? 0x3A4130 : 0xE6E7C9)
        let garden = hexColor(dark ? 0x304334 : 0xD6E3C7)
        let wetland = hexColor(dark ? 0x2B4140 : 0xC6DCD2)
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
            "park", park,
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

    private func forestPatternName(dark: Bool, dense: Bool, leaf: String = "unknown") -> String {
        "naviastra-forest-\(dense ? "dense-" : "")\(dark ? "dark" : "light")-\(leaf)"
    }

    private func forestPatternExpression(dark: Bool, dense: Bool) -> NSExpression {
        NSExpression(mglJSONObject: [
            "match", ["get", "leaf_type"],
            "broadleaved", forestPatternName(dark: dark, dense: dense, leaf: "broadleaved"),
            "needleleaved", forestPatternName(dark: dark, dense: dense, leaf: "needleleaved"),
            "mixed", forestPatternName(dark: dark, dense: dense, leaf: "mixed"),
            forestPatternName(dark: dark, dense: dense)
        ])
    }

    private func waterPatternName(dark: Bool) -> String {
        "naviastra-water-\(dark ? "dark" : "light")"
    }

    private func forestTreePattern(dark: Bool, dense: Bool, leaf: String) -> UIImage {
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

            for (index, tree) in positions.enumerated() {
                let (x, y, size) = tree
                let half = size / 2
                context.setFillColor(index.isMultiple(of: 2) ? canopy : highlight)
                if leaf == "needleleaved" || (leaf == "mixed" && index.isMultiple(of: 2)) {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: x, y: y - half))
                    path.addLine(to: CGPoint(x: x - half * 0.8, y: y + half * 0.7))
                    path.addLine(to: CGPoint(x: x + half * 0.8, y: y + half * 0.7))
                    path.closeSubpath()
                    context.addPath(path)
                    context.fillPath()
                } else {
                    // Unknown leaf types get neutral grain, never an inferred species.
                    let diameter = leaf == "unknown" ? size * 0.4 : size * 0.85
                    context.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2,
                                                   width: diameter, height: diameter * 0.9))
                }
            }
        }
    }

    private func waterWavePattern(dark: Bool) -> UIImage {
        let tileSize: CGFloat = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: tileSize, height: tileSize), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            // Short, staggered highlights stay inside the tile so repeats have
            // no cut wave ends or visible seams. This is decorative texture.
            let ripples: [(CGFloat, CGFloat, CGFloat)] = [
                (14, 22, 27), (76, 43, 33), (29, 78, 31), (83, 108, 22)
            ]
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setLineCap(.round)
            context.setStrokeColor(color(dark ? 0xA3C4CA : 0xEDF6F5)
                .withAlphaComponent(dark ? 0.20 : 0.32).cgColor)
            context.setLineWidth(1.2)
            context.setShadow(offset: .zero, blur: 1.5,
                              color: color(dark ? 0xA3C4CA : 0xEDF6F5).withAlphaComponent(0.10).cgColor)
            for (x, y, length) in ripples {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y))
                path.addCurve(to: CGPoint(x: x + length, y: y),
                              control1: CGPoint(x: x + length * 0.33, y: y - 1.8),
                              control2: CGPoint(x: x + length * 0.67, y: y + 1.8))
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

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
