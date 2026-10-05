import Foundation
import Observation

@MainActor
@Observable
final class MapStore {
    var transportPositionIconsEnabled: Bool { didSet { persist(transportPositionIconsEnabled, forKey: "transportPositionIconsEnabled") } }
    var markerAppearance: NavigationMarkerAppearance {
        didSet {
            guard !isReloading, let data = try? JSONEncoder().encode(markerAppearance) else { return }
            defaults.set(data, forKey: "navigationMarkerAppearance")
        }
    }
    var mapBase: String { didSet { persist(mapBase, forKey: "mapBase") } }
    var mapAppearance: String { didSet { persist(mapAppearance, forKey: "mapAppearance") } }
    var mapDimension: String { didSet { persist(mapDimension, forKey: "mapDimension") } }
    var mapRoadSignsVisible: Bool { didSet { persist(mapRoadSignsVisible, forKey: "mapRoadSignsVisible") } }
    var mapTrafficVisible: Bool { didSet { persist(mapTrafficVisible, forKey: "mapTrafficVisible") } }
    var mapPOICategories: Int { didSet { persist(mapPOICategories, forKey: "mapPOICategories") } }
    var shopLogosEnabled: Bool { didSet { persist(shopLogosEnabled, forKey: "shopLogosEnabled") } }
    var mapPOIVisible: Bool { didSet { persist(mapPOIVisible, forKey: "mapPOIVisible") } }
    var mapSafetyPOICategories: Int { didSet { persist(mapSafetyPOICategories, forKey: "mapSafetyPOICategories") } }
    var mapBuildingsVisible: Bool { didSet { persist(mapBuildingsVisible, forKey: "mapBuildingsVisible") } }
    var mapTransitVisible: Bool { didSet { persist(mapTransitVisible, forKey: "mapTransitVisible") } }
    var mapCyclingVisible: Bool { didSet { persist(mapCyclingVisible, forKey: "mapCyclingVisible") } }
    var cyclingPathsStatus: OSMCyclingPathsStatus = .disabled
    var roadPOIStatus: MapRoadPOIStatus = .disabled

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isReloading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        markerAppearance = NavigationMarkerAppearance.load(from: defaults)
        if !defaults.bool(forKey: "heightLimitPOIMigrated") {
            let categories = defaults.object(forKey: "mapSafetyPOICategories") as? Int
                ?? MapSafetyPOICategory.allMask
            defaults.set(categories | MapSafetyPOICategory.heightLimits.mask,
                         forKey: "mapSafetyPOICategories")
            defaults.set(true, forKey: "heightLimitPOIMigrated")
        }
        if !defaults.bool(forKey: "weightLimitPOIMigrated") {
            let categories = defaults.object(forKey: "mapSafetyPOICategories") as? Int
                ?? MapSafetyPOICategory.allMask
            defaults.set(categories | MapSafetyPOICategory.weightLimits.mask | MapSafetyPOICategory.truckRestrictions.mask,
                         forKey: "mapSafetyPOICategories")
            defaults.set(true, forKey: "weightLimitPOIMigrated")
        }
        transportPositionIconsEnabled = defaults.object(forKey: "transportPositionIconsEnabled") as? Bool ?? false
        mapBase = defaults.string(forKey: "mapBase") ?? BaseMap.standard.rawValue
        mapAppearance = defaults.string(forKey: "mapAppearance") ?? MapAppearance.auto.rawValue
        mapDimension = defaults.string(forKey: "mapDimension") ?? MapDimension.flat.rawValue
        mapRoadSignsVisible = defaults.object(forKey: "mapRoadSignsVisible") as? Bool ?? false
        mapTrafficVisible = defaults.object(forKey: "mapTrafficVisible") as? Bool ?? true
        mapPOICategories = defaults.object(forKey: "mapPOICategories") as? Int ?? MapPOICategory.allMask
        shopLogosEnabled = defaults.object(forKey: "shopLogosEnabled") as? Bool ?? true
        mapPOIVisible = defaults.object(forKey: "mapPOIVisible") as? Bool ?? true
        mapSafetyPOICategories = defaults.object(forKey: "mapSafetyPOICategories") as? Int ?? MapSafetyPOICategory.allMask
        mapBuildingsVisible = defaults.object(forKey: "mapBuildingsVisible") as? Bool ?? true
        mapTransitVisible = defaults.object(forKey: "mapTransitVisible") as? Bool ?? false
        mapCyclingVisible = defaults.object(forKey: "mapCyclingVisible") as? Bool ?? false
    }

    func settings(for capabilities: MapProviderCapabilities) -> MapSettings {
        let requestedBase = BaseMap(rawValue: mapBase) ?? .standard
        return MapSettings(
            baseMap: capabilities.supports(requestedBase) ? requestedBase : .standard,
            appearance: MapAppearance(rawValue: mapAppearance) ?? .auto,
            cameraMode: capabilities.supports3DCamera ? (MapDimension(rawValue: mapDimension) ?? .flat) : .flat,
            overlays: MapOverlays(
                traffic: capabilities.supportsTrafficOverlay && mapTrafficVisible,
                poi: capabilities.supportsPOIToggle && mapPOIVisible,
                buildings3D: capabilities.supports3DBuildings && mapBuildingsVisible,
                transit: capabilities.supportsTransitOverlay && mapTransitVisible,
                cycling: capabilities.supportsCyclingOverlay && mapCyclingVisible),
            poiCategories: Set(MapPOICategory.allCases.filter { mapPOICategories & $0.mask != 0 }),
            shopLogosEnabled: shopLogosEnabled,
            transportPositionIconsEnabled: transportPositionIconsEnabled,
            markerAppearance: markerAppearance,
            roadSignsVisible: mapRoadSignsVisible,
            safetyPOICategories: Set(MapSafetyPOICategory.allCases.filter {
                mapSafetyPOICategories & $0.mask != 0
            }))
    }

    func reloadFromDefaults() {
        isReloading = true
        markerAppearance = NavigationMarkerAppearance.load(from: defaults)
        transportPositionIconsEnabled = defaults.object(forKey: "transportPositionIconsEnabled") as? Bool ?? false
        mapBase = defaults.string(forKey: "mapBase") ?? BaseMap.standard.rawValue
        mapAppearance = defaults.string(forKey: "mapAppearance") ?? MapAppearance.auto.rawValue
        mapDimension = defaults.string(forKey: "mapDimension") ?? MapDimension.flat.rawValue
        mapRoadSignsVisible = defaults.object(forKey: "mapRoadSignsVisible") as? Bool ?? false
        mapTrafficVisible = defaults.object(forKey: "mapTrafficVisible") as? Bool ?? true
        mapPOICategories = defaults.object(forKey: "mapPOICategories") as? Int ?? MapPOICategory.allMask
        shopLogosEnabled = defaults.object(forKey: "shopLogosEnabled") as? Bool ?? true
        mapPOIVisible = defaults.object(forKey: "mapPOIVisible") as? Bool ?? true
        mapSafetyPOICategories = defaults.object(forKey: "mapSafetyPOICategories") as? Int ?? MapSafetyPOICategory.allMask
        mapBuildingsVisible = defaults.object(forKey: "mapBuildingsVisible") as? Bool ?? true
        mapTransitVisible = defaults.object(forKey: "mapTransitVisible") as? Bool ?? false
        mapCyclingVisible = defaults.object(forKey: "mapCyclingVisible") as? Bool ?? false
        isReloading = false
    }

    private func persist<T>(_ value: T, forKey key: String) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key)
    }
}
