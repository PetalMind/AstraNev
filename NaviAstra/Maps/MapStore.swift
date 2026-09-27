import Foundation
import Observation

@MainActor
@Observable
final class MapStore {
    var mapBase: String { didSet { persist(mapBase, forKey: "mapBase") } }
    var mapAppearance: String { didSet { persist(mapAppearance, forKey: "mapAppearance") } }
    var mapDimension: String { didSet { persist(mapDimension, forKey: "mapDimension") } }
    var mapTrafficVisible: Bool { didSet { persist(mapTrafficVisible, forKey: "mapTrafficVisible") } }
    var mapPOICategories: Int { didSet { persist(mapPOICategories, forKey: "mapPOICategories") } }
    var mapPOIVisible: Bool { didSet { persist(mapPOIVisible, forKey: "mapPOIVisible") } }
    var mapBuildingsVisible: Bool { didSet { persist(mapBuildingsVisible, forKey: "mapBuildingsVisible") } }
    var mapTransitVisible: Bool { didSet { persist(mapTransitVisible, forKey: "mapTransitVisible") } }
    var mapCyclingVisible: Bool { didSet { persist(mapCyclingVisible, forKey: "mapCyclingVisible") } }
    var cyclingPathsStatus: OSMCyclingPathsStatus = .disabled

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isReloading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mapBase = defaults.string(forKey: "mapBase") ?? BaseMap.standard.rawValue
        mapAppearance = defaults.string(forKey: "mapAppearance") ?? MapAppearance.auto.rawValue
        mapDimension = defaults.string(forKey: "mapDimension") ?? MapDimension.flat.rawValue
        mapTrafficVisible = defaults.object(forKey: "mapTrafficVisible") as? Bool ?? true
        mapPOICategories = defaults.object(forKey: "mapPOICategories") as? Int ?? MapPOICategory.allMask
        mapPOIVisible = defaults.object(forKey: "mapPOIVisible") as? Bool ?? true
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
            poiCategories: Set(MapPOICategory.allCases.filter { mapPOICategories & $0.mask != 0 }))
    }

    func reloadFromDefaults() {
        isReloading = true
        mapBase = defaults.string(forKey: "mapBase") ?? BaseMap.standard.rawValue
        mapAppearance = defaults.string(forKey: "mapAppearance") ?? MapAppearance.auto.rawValue
        mapDimension = defaults.string(forKey: "mapDimension") ?? MapDimension.flat.rawValue
        mapTrafficVisible = defaults.object(forKey: "mapTrafficVisible") as? Bool ?? true
        mapPOICategories = defaults.object(forKey: "mapPOICategories") as? Int ?? MapPOICategory.allMask
        mapPOIVisible = defaults.object(forKey: "mapPOIVisible") as? Bool ?? true
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
