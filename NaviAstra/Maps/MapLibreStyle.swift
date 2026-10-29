#if os(iOS)
import Foundation
import MapLibre
import OSLog
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
    private var poiLayerIDs: [String] = []
    private let poiVisualRenderer = MapPOIVisualRenderer()
    private let buildingFallbackRenderer = MapBuildingFallbackRenderer()
    private var detailWork: DispatchWorkItem?
    private var lastDetailRefresh = Date.distantPast
    private weak var detailMap: MLNMapView?
    private var detailSettings: MapSettings?
    private var detailSelected: SearchResult?
    private var detailFocus: CLLocationCoordinate2D?
    private var detailRoute: [CLLocationCoordinate2D] = []
    private var detailEnabled = false
    private var detailGeneration = 0
    private var lastDetailLog = Date.distantPast
    private let detailLogger = Logger(subsystem: "NaviAstra", category: "MapDetails")
    private let crosswalkRenderer = MapCrosswalkRenderer()
    private let surfaceNetworkRenderer = MapSurfaceNetworkRenderer()
    private let sportSurfaceRenderer = MapSportSurfaceRenderer()
    private let streetFurnitureRenderer = MapStreetFurnitureRenderer()
    private var poiSettings: MapSettings?
    private var poiDark = false
    private var poiDensity: Int?
    private var poiRouteFilterKey = ""
    private var poiRouteFilter: MapPOIRouteFilter = .unrestricted
    private var configured = false
    private var buildingFacadeLayer: MapBuildingFacadeLayer?
    private var buildingHeightKey = "render_height"
    private var buildingBaseKey = "render_min_height"

    func reset() {
        suspendDetails()
        satelliteStyle.stopRecovery()
        detailFocus = nil
        detailRoute = []
        buildingFallbackRenderer.reset()
        streetFurnitureRenderer.reset()
        lastKey = ""
        satelliteStyle = SatelliteMapStyle()
        shopLogoNames = [:]
        shopLogoImages = [:]
        shopLogoDark = nil
        poiLayerIDs.removeAll()
        poiDensity = nil
        poiRouteFilterKey = ""
        poiRouteFilter = .unrestricted
        configured = false
        buildingFacadeLayer = nil
        buildingHeightKey = "render_height"
        buildingBaseKey = "render_min_height"
    }

    func updateSatelliteRecovery(on map: MLNMapView, enabled: Bool, renderingEnabled: Bool) {
        satelliteStyle.updateRecovery(on: map, enabled: enabled, renderingEnabled: renderingEnabled)
    }

    func satelliteTileOperation(_ operation: MLNTileOperation, sourceID: String, tile: SatelliteTileAddress) {
        satelliteStyle.tileOperation(operation, sourceID: sourceID, tile: tile)
    }

    func stopSatelliteRecovery() { satelliteStyle.stopRecovery() }

    func apply(to style: MLNStyle, settings: MapSettings, dark: Bool,
               activelyNavigating: Bool, zoom: Double, coordinate: CLLocationCoordinate2D) {
        if !configured {
            configure(style)
            configured = true
        }
        poiSettings = settings
        poiDark = dark
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
                if id.hasPrefix("naviastra-low-vegetation-") {
                    let wetland = id.hasSuffix("wetland")
                    layer.fillPattern = NSExpression(forConstantValue: vegetationPatternName(dark: dark, wetland: wetland))
                    layer.fillOpacity = vegetationPatternOpacity(navigating: navigating)
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
                    // A sprite fill takes precedence over fillColor. Remove the
                    // provider's opaque daytime texture before applying our palette.
                    layer.fillPattern = nil
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
                    layer.fillOutlineColor = MapBuildingAppearance.outline(dark: dark)
                }
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer,
               layer.sourceLayerIdentifier == "building" {
                layer.isVisible = settings.overlays.buildings3D && settings.cameraMode == .threeD
                layer.fillExtrusionColor = MapBuildingAppearance.color(dark: dark, heightKey: "render_height")
                MapBuildingAppearance.applySolidRendering(to: layer)
                layer.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
                layer.fillExtrusionRoundedCornerDistance = NSExpression(forConstantValue: MapBuildingAppearance.cornerDistance)
            }
            if let layer = layer as? MLNLineStyleLayer {
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
                    layer.isVisible = false
                    continue
                }
                if id == MapPOIVisualRenderer.pointsID {
                    layer.iconImageName = poiIconExpression(dark: dark)
                    layer.textColor = poiColorExpression(dark: dark)
                    layer.iconScale = NSExpression(mglJSONObject: [
                        "interpolate", ["linear"], ["zoom"], 12, 0.64, 17, 0.82
                    ])
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
        streetFurnitureRenderer.apply(to: style, settings: settings, dark: dark)
        poiVisualRenderer.apply(to: style, settings: settings, zoom: zoom, dark: dark, routeFilter: poiRouteFilter)
        satelliteStyle.apply(to: style, enabled: settings.baseMap == .satellite)
        poiDensity = density
    }

    func updatePOIDensity(to style: MLNStyle, zoom: Double) {
        guard configured else { return }
        let density = densityLevel(for: zoom)
        guard poiDensity != density else { return }
        if let settings = poiSettings {
            poiVisualRenderer.apply(to: style, settings: settings, zoom: zoom, dark: poiDark, routeFilter: poiRouteFilter)
        }
        poiDensity = density
    }

    func updatePOIRouteContext(_ state: NavigationState, context: MapDisplayContext) {
        detailFocus = (state.cameraLocation ?? state.location)?.coordinate.cl
        let filtered = context == .driving || context == .routePreview || context == .approachingDestination
        let traveling = state.status == .navigating || state.status == .rerouting
        let confirmed = !traveling || MapDisplayPriorityEngine.canPresentRouteAlerts(state)
        let bucket = Int(state.roadAlertRouteDistance / 100)
        let key = "\(filtered)-\(confirmed)-\(state.route?.id.uuidString ?? "none")-\(traveling ? bucket : 0)"
        guard key != poiRouteFilterKey else { return }
        poiRouteFilterKey = key
        detailRoute = []
        poiDensity = nil
        guard filtered else { poiRouteFilter = .unrestricted; return }
        guard confirmed, let route = state.route else { poiRouteFilter = .hidden; return }
        let geometry = RouteProgressGeometry(route)
        let start = traveling ? max(0, Double(bucket) * 100) : 0
        let end = min(geometry.length, start + (traveling ? 5_000 : 20_000))
        detailRoute = stride(from: start, through: min(end, start + 1_000), by: 40.0).compactMap {
            geometry.coordinate(at: $0)?.cl
        }
        var polygons: [[[[Double]]]] = []
        for distance in stride(from: start, through: end, by: 100.0) {
            guard let center = geometry.coordinate(at: distance) else { continue }
            let dy = 125.0 / 111_320
            let dx = dy / max(0.1, cos(center.latitude * .pi / 180))
            let x = center.longitude, y = center.latitude
            polygons.append([[[x - dx, y - dy], [x + dx, y - dy], [x + dx, y + dy],
                              [x - dx, y + dy], [x - dx, y - dy]]])
        }
        poiRouteFilter = polygons.isEmpty ? .hidden : .corridor(NSPredicate(mglJSONObject: [
            "within", ["type": "MultiPolygon", "coordinates": polygons]
        ]))
    }

    private func densityLevel(for zoom: Double) -> Int {
        Int((max(0, min(24, zoom)) * 2).rounded(.down))
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
            for wetland in [false, true] {
                style.setImage(vegetationPattern(dark: dark, wetland: wetland),
                               forName: vegetationPatternName(dark: dark, wetland: wetland))
            }
            style.setImage(waterWavePattern(dark: dark), forName: waterPatternName(dark: dark))
        }
        for layer in style.layers {
            if let layer = layer as? MLNSymbolStyleLayer, layer.sourceLayerIdentifier == "poi" {
                layer.isVisible = false
            }
            if let layer = layer as? MLNFillStyleLayer, layer.sourceLayerIdentifier == "building" {
                layer.minimumZoomLevel = 15
                layer.maximumZoomLevel = 24 // Retain footprints when extrusion is disabled.
            }
            if let layer = layer as? MLNFillExtrusionStyleLayer,
               layer.sourceLayerIdentifier == "building" {
                // OpenMapTiles omits hide_3d unless an outline must be hidden.
                // Include that missing value explicitly in the native style filter.
                layer.minimumZoomLevel = Float(MapEnvironmentModelPolicy.minimumZoom)
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
        installVegetationPatternLayers(in: style)
        installForestTreePatternLayers(in: style)
        installWaterShorelineLayer(in: style)
        installWaterWavePatternLayers(in: style)
        MapEnvironmentStyle.configure(in: style)
        sportSurfaceRenderer.configure(in: style)
        surfaceNetworkRenderer.configure(in: style)
        installBuildingFacadeLayer(in: style)
        streetFurnitureRenderer.configure(in: style)
        MapOverlayDepthLayer.install(in: style)
        poiVisualRenderer.configure(in: style)
        poiLayerIDs = [MapPOIVisualRenderer.pointsID]
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

    private func installBuildingFacadeLayer(in style: MLNStyle) {
        guard style.layer(withIdentifier: MapBuildingFacadeLayer.layerID) == nil,
              let building = (style.layer(withIdentifier: MapTilerEnvironmentStyle.buildingLayerID) as? MLNFillExtrusionStyleLayer)
                ?? style.layers.compactMap({ $0 as? MLNFillExtrusionStyleLayer })
                    .last(where: { $0.sourceLayerIdentifier == "building" }) else { return }
        let planet = building.identifier == MapTilerEnvironmentStyle.buildingLayerID
        buildingHeightKey = planet ? "height" : "render_height"
        buildingBaseKey = planet ? "height_min" : "render_min_height"
        // Keep one native body and its exact roof geometry. The existing facade
        // pass tints the same triangulated roof inside its own depth-tested color
        // target; it never adds a competing offset extrusion or changes its height.
        let layer = MapBuildingFacadeLayer(identifier: MapBuildingFacadeLayer.layerID)
        // Road-arrow symbols precede buildings in Liberty. Anchoring to the first
        // symbol puts the lights underneath the bodies that they decorate.
        // Use the last body instead; place labels and route overlays stay above.
        let topBuilding = style.layers.last {
            ($0 as? MLNFillExtrusionStyleLayer)?.sourceLayerIdentifier == "building"
        } ?? building
        style.insertLayer(layer, above: topBuilding)
        buildingFacadeLayer = layer
    }

    func updateBuildingFacadeVisibility(on map: MLNMapView, settings: MapSettings, dark: Bool,
                                        renderingEnabled: Bool) {
        buildingFacadeLayer?.updateVisibility(on: map, settings: settings, dark: dark,
                                             renderingEnabled: renderingEnabled)
    }

    func updateBuildingFacades(on map: MLNMapView, settings: MapSettings, dark: Bool) {
        updateBuildingFacadeVisibility(on: map, settings: settings, dark: dark, renderingEnabled: true)
        guard let style = map.style else { return }
        let visibleBuildings = Set(style.layers.compactMap { layer -> String? in
            guard let extrusion = layer as? MLNFillExtrusionStyleLayer,
                  MapTilerEnvironmentStyle.isBuildingLayer(extrusion), extrusion.isVisible else { return nil }
            return extrusion.identifier
        })
        buildingFacadeLayer?.updateGeometry(on: map, layerIDs: visibleBuildings,
                                           heightKey: buildingHeightKey, baseKey: buildingBaseKey)
    }

    private func installVegetationPatternLayers(in style: MLNStyle) {
        guard let source = style.source(withIdentifier: "openmaptiles"),
              let land = style.layers.compactMap({ $0 as? MLNFillStyleLayer })
                .last(where: { $0.sourceLayerIdentifier == "landcover" }) else { return }
        let water = style.layers.first {
            guard $0 is MLNFillStyleLayer || $0 is MLNLineStyleLayer,
                  let vector = $0 as? MLNVectorStyleLayer else { return false }
            return vector.sourceLayerIdentifier == "water" || vector.sourceLayerIdentifier == "waterway"
        }
        for wetland in [false, true] {
            let id = "naviastra-low-vegetation-" + (wetland ? "wetland" : "grass")
            guard style.layer(withIdentifier: id) == nil else { continue }
            let layer = MLNFillStyleLayer(identifier: id, source: source)
            layer.sourceLayerIdentifier = "landcover"
            layer.predicate = wetland
                ? NSPredicate(format: "class == %@ OR subclass IN %@", "wetland",
                              ["marsh", "reedbed", "swamp", "bog", "wetland", "saltmarsh", "tidalflat", "wet_meadow"])
                : NSPredicate(format: "subclass IN %@", ["grass", "grassland", "meadow"])
            layer.minimumZoomLevel = 15
            layer.fillPattern = NSExpression(forConstantValue: vegetationPatternName(dark: false, wetland: wetland))
            layer.fillOpacity = vegetationPatternOpacity(navigating: false)
            // Water, paths and roads remain above the terrain symbols.
            if let water { style.insertLayer(layer, below: water) }
            else { style.insertLayer(layer, above: land) }
        }
    }

    private func vegetationPatternName(dark: Bool, wetland: Bool) -> String {
        "naviastra-low-vegetation-sprite-\(wetland ? "wetland" : "grass")-\(dark ? "dark" : "light")"
    }

    private func vegetationPatternOpacity(navigating: Bool) -> NSExpression {
        NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
            15, 0, 17, navigating ? 0.16 : 0.30, 19, navigating ? 0.22 : 0.42])
    }

    /// Decorative cartographic marks inside provider polygons, not individual plants.
    private func vegetationPattern(dark: Bool, wetland: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { output in
            let context = output.cgContext
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(1.1)
            context.setStrokeColor(color(dark ? 0x85A99A : 0x668C72).cgColor)
            let positions: [(CGFloat, CGFloat)] = [(15, 18), (63, 12), (40, 49), (79, 69), (18, 82)]
            for (x, y) in positions {
                let height: CGFloat = wetland ? 7 : 3.5
                context.move(to: CGPoint(x: x - 3, y: y))
                context.addLine(to: CGPoint(x: x - 5, y: y - height * 0.7))
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x, y: y - height))
                context.move(to: CGPoint(x: x + 3, y: y))
                context.addLine(to: CGPoint(x: x + 5, y: y - height * 0.8))
                context.strokePath()
                if wetland {
                    context.setStrokeColor(color(dark ? 0x719CA4 : 0x739CA0).cgColor)
                    context.move(to: CGPoint(x: x - 6, y: y + 3))
                    context.addLine(to: CGPoint(x: x + 5, y: y + 3))
                    context.strokePath()
                    context.setStrokeColor(color(dark ? 0x85A99A : 0x668C72).cgColor)
                }
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
            lastWaterFill.predicate,
            NSPredicate(format: "class IN %@", ["ocean", "lake", "river", "pond", "dock"]),
            NSPredicate(format: "intermittent == nil OR intermittent != 1")
        ].compactMap { $0 })
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
            ["grass", "grassland", "golf_course"], grass,
            ["meadow"], meadow,
            ["orchard", "vineyard", "farm", "farmland", "plant_nursery"], cultivated,
            ["garden", "flowerbed", "allotments", "recreation_ground", "village_green"], garden,
            ["marsh", "reedbed", "swamp", "bog", "wetland", "saltmarsh", "tidalflat", "wet_meadow"], wetland,
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
        var normalized: [Any] = ["match", ["get", "_kind"]]
        for kind in kinds { normalized += [kind.rawValue, poiImageName(kind, dark: dark)] }
        normalized.append(matchExpression(for: "subclass", fallback: classMatch))
        let fallback: [Any] = ["coalesce", ["get", "_sprite"], normalized]
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
        return NSExpression(mglJSONObject: ["to-color", ["get", "_color"], fallback])
    }

    func refreshObjectModels(roadPOIs: [MapRoadPOI], alerts: [RoadSafetyAlert], stops: [TransitStop], places: [SearchResult]) {
        var points = roadPOIs.compactMap { poi -> MapObjectModelPoint? in
            guard let kind = MapObjectModelInput.roadKind(category: poi.category) else { return nil }
            return .init(coordinate: poi.coordinate.cl, kind: kind, safetyCategory: poi.category,
                         identity: poi.id, label: poi.title, sign: kind == .sign ? RoadSignSymbol(poi) : nil, priority: 3)
        }
        points += alerts.compactMap { alert -> MapObjectModelPoint? in
            guard let category = MapObjectModelInput.roadCategory(alert: alert),
                  let kind = MapObjectModelInput.roadKind(category: category) else { return nil }
            return .init(coordinate: alert.coordinate.cl, kind: kind, safetyCategory: category,
                         identity: alert.mapPOIID ?? alert.id, label: alert.title,
                         sign: kind == .sign ? RoadSignSymbol(alert) : nil, priority: 3)
        }
        points += stops.map {
            .init(coordinate: $0.coordinate.cl, kind: $0.mapModes.contains(.rail) || $0.mapModes.contains(.metro) ? .station : .stop,
                  category: .transit, identity: "transit:\($0.id)", label: $0.name)
        }
        points += places.compactMap { place -> MapObjectModelPoint? in
            guard place.isPOI, let kind = MapObjectModelInput.serviceKind(category: place.category) else { return nil }
            return .init(coordinate: place.destination.coordinate.cl, kind: kind, category: kind == .charger ? .charging : .shopping,
                         identity: place.osmID ?? "", label: place.destination.name, priority: 3)
        }
        streetFurnitureRenderer.additionalPoints = points
        scheduleDetails()
    }

    func refreshPOIs(on map: MLNMapView, settings: MapSettings, dark: Bool, selected: SearchResult?) {
        poiDark = dark
        detailSelected = selected
        detailMap = map
        detailSettings = settings
        scheduleDetails()
    }

    func refreshCrosswalks(on map: MLNMapView, settings: MapSettings, renderingEnabled: Bool) {
        detailMap = map
        detailSettings = settings
        detailEnabled = renderingEnabled
        if !renderingEnabled { suspendDetails(); return }
        scheduleDetails()
    }

    func suspendDetails() {
        detailGeneration &+= 1
        detailEnabled = false
        detailWork?.cancel()
        detailWork = nil
        crosswalkRenderer.suspend()
        surfaceNetworkRenderer.suspend()
        sportSurfaceRenderer.suspend()
        streetFurnitureRenderer.suspend()
        poiVisualRenderer.suspend()
    }

    private func scheduleDetails() {
        guard detailEnabled, detailWork == nil else { return }
        let delay = max(0, MapDetailPolicy.refreshInterval - Date().timeIntervalSince(lastDetailRefresh))
        let generation = detailGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.detailGeneration == generation else { return }
            self.detailWork = nil
            guard self.detailEnabled, let map = self.detailMap, let settings = self.detailSettings else { return }
            let started = Date()
            self.lastDetailRefresh = .now
            self.buildingFallbackRenderer.refresh(on: map, settings: settings)
            self.crosswalkRenderer.refresh(on: map, enabled: settings.baseMap != .satellite)
            self.surfaceNetworkRenderer.refresh(on: map, settings: settings, dark: self.poiDark)
            self.sportSurfaceRenderer.refresh(on: map, settings: settings, dark: self.poiDark, enabled: true)
            self.streetFurnitureRenderer.refresh(on: map, settings: settings, enabled: true,
                focus: self.detailFocus, route: self.detailRoute, routeFilter: self.poiRouteFilter)
            self.poiVisualRenderer.refresh(on: map, settings: settings, dark: self.poiDark, selected: self.detailSelected)
            #if DEBUG
            if Date().timeIntervalSince(self.lastDetailLog) >= 10 {
                self.lastDetailLog = .now
                let milliseconds = Date().timeIntervalSince(started) * 1_000
                self.detailLogger.debug("Map detail update: \(milliseconds) ms")
            }
            #endif
        }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
#endif
